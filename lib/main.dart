import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' hide context;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:barcode_scan2/barcode_scan2.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const OTTrackerProApp());

class OTTrackerProApp extends StatelessWidget {
  const OTTrackerProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OT TRACKER PRO',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00796B),
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const DashboardScreen(),
    );
  }
}

// ==========================================
// 1. Database Engine (v6 - Advanced Features)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ot_tracker_v6.db'); 
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('''
        CREATE TABLE items (
          id INTEGER PRIMARY KEY AUTOINCREMENT, 
          name TEXT, 
          category TEXT, 
          barcode TEXT,
          lotNumber TEXT,
          initialQuantity INTEGER, 
          quantity INTEGER, 
          stockAlert INTEGER, 
          expiryDate TEXT, 
          expiryAlertMonths INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE audit (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          itemName TEXT,
          amount INTEGER,
          patientId TEXT,
          date TEXT
        )
      ''');
    });
  }

  Future<int> insertItem(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('items', row);
  }

  Future<void> updateBatchFull(int id, String itemName, String barcode, String lotNumber, int qty, String expiry, int stockAlert, int expiryAlertMonths) async {
    final db = await instance.database;
    await db.update('items', {
      'barcode': barcode,
      'lotNumber': lotNumber,
      'initialQuantity': qty,
      'quantity': qty,
      'expiryDate': expiry,
      'stockAlert': stockAlert,
      'expiryAlertMonths': expiryAlertMonths
    }, where: 'id = ?', whereArgs: [id]);
    
    await db.update('items', {
      'stockAlert': stockAlert,
      'expiryAlertMonths': expiryAlertMonths
    }, where: 'name = ?', whereArgs: [itemName]);
  }

  Future<int> deleteBatch(int id) async {
    final db = await instance.database;
    return await db.delete('items', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getGroupedItems() async {
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT name, category, barcode,
             SUM(initialQuantity) as totalInitial,
             SUM(initialQuantity - quantity) as totalConsumed,
             SUM(quantity) as totalQty, 
             MIN(CASE WHEN quantity > 0 THEN expiryDate ELSE NULL END) as nearestExpiry, 
             MAX(stockAlert) as stockAlert, 
             MAX(expiryAlertMonths) as expiryAlertMonths
      FROM items 
      GROUP BY name 
      ORDER BY name ASC
    ''');
  }

  Future<List<Map<String, dynamic>>> getBatches(String name) async {
    final db = await instance.database;
    return await db.query('items', where: 'name = ?', whereArgs: [name], orderBy: 'expiryDate ASC');
  }

  Future<List<Map<String, dynamic>>> getAuditTrail() async {
    final db = await instance.database;
    return await db.query('audit', orderBy: 'id DESC');
  }

  Future<void> withdrawItemSmart(String itemName, int amountToWithdraw, String patientId) async {
    final db = await instance.database;
    final batches = await db.query('items', where: 'name = ? AND quantity > 0', whereArgs: [itemName], orderBy: 'expiryDate ASC');
    int remaining = amountToWithdraw;

    for (var batch in batches) {
      if (remaining <= 0) break;
      int currentQty = batch['quantity'] as int;
      int batchId = batch['id'] as int;

      if (currentQty <= remaining) {
        await db.update('items', {'quantity': 0}, where: 'id = ?', whereArgs: [batchId]);
        remaining -= currentQty;
      } else {
        await db.update('items', {'quantity': currentQty - remaining}, where: 'id = ?', whereArgs: [batchId]);
        remaining = 0;
      }
    }

    await db.insert('audit', {
      'itemName': itemName,
      'amount': amountToWithdraw,
      'patientId': patientId.isEmpty ? 'No Patient ID' : patientId,
      'date': "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2,'0')}-${DateTime.now().day.toString().padLeft(2,'0')} ${DateTime.now().hour.toString().padLeft(2,'0')}:${DateTime.now().minute.toString().padLeft(2,'0')}"
    });
  }
}

// ==========================================
// 2. Main Dashboard & Audit Logic
// ==========================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Map<String, dynamic>> _allItems = [];
  List<Map<String, dynamic>> _filteredItems = [];
  
  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedCategory = 'All';
  List<String> _categories = ['All'];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data = await DatabaseHelper.instance.getGroupedItems();
    Set<String> uniqueCategories = {'All'};
    for (var item in data) {
      String cat = item['category'].toString().trim();
      if (cat.isNotEmpty && cat != 'null') uniqueCategories.add(cat);
    }
    setState(() {
      _allItems = data;
      _categories = uniqueCategories.toList();
      _applyFilters();
    });
  }

  void _applyFilters() {
    setState(() {
      String q = _searchCtrl.text.toLowerCase();
      _filteredItems = _allItems.where((item) {
        final matchesSearch = item['name'].toString().toLowerCase().contains(q) || 
                              item['barcode'].toString().toLowerCase().contains(q);
        final matchesCategory = _selectedCategory == 'All' || item['category'] == _selectedCategory;
        return matchesSearch && matchesCategory;
      }).toList();
    });
  }

  Future<void> _scanBarcodeForSearch() async {
    try {
      var result = await BarcodeScanner.scan();
      if (result.type == ResultType.Barcode && result.rawContent.isNotEmpty && mounted) {
        setState(() {
          _searchCtrl.text = result.rawContent;
          _applyFilters();
        });
      }
    } catch (e) {
      // User canceled or error
    }
  }

  Future<void> _backupDatabase() async {
    final dbPath = join(await getDatabasesPath(), 'ot_tracker_v6.db');
    await Share.shareXFiles([XFile(dbPath)], text: 'OT Tracker Pro Database Backup');
  }

  void _viewAuditLog() async {
    final logs = await DatabaseHelper.instance.getAuditTrail();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Consumption Audit Log', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF00796B))),
            ),
            Expanded(
              child: logs.isEmpty ? const Center(child: Text('No records yet.')) : ListView.builder(
                itemCount: logs.length,
                itemBuilder: (ctx, i) {
                  final log = logs[i];
                  return ListTile(
                    leading: const Icon(Icons.history, color: Colors.teal),
                    title: Text('${log['itemName']} (Qty: ${log['amount']})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Patient/Note: ${log['patientId']}'),
                    trailing: Text(log['date'].toString(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  );
                },
              ),
            )
          ],
        ),
      )
    );
  }

  Future<void> _generatePdfReport() async {
    List<List<String>> reportData = [];
    for (var item in _filteredItems) {
      final batches = await DatabaseHelper.instance.getBatches(item['name']);
      List<String> activeExpiries = batches.where((b) => (b['quantity'] as int) > 0).map((b) => b['expiryDate'].toString()).toSet().toList();
      reportData.add([
        item['name'].toString(),
        item['category'].toString(),
        item['totalInitial'].toString(),
        item['totalConsumed'].toString(),
        item['totalQty'].toString(),
        activeExpiries.isEmpty ? 'Fully Consumed' : activeExpiries.join(',\n')
      ]);
    }

    final pdf = pw.Document();
    final String currentDate = "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')} ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape, 
      margin: const pw.EdgeInsets.all(30),
      build: (pw.Context context) {
        return [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Noor Alyemen Eye & E.N.T. Consulting Center', style: pw.TextStyle(fontSize: 14, color: PdfColors.grey700)),
              pw.SizedBox(height: 5),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('OT-Tracker Pro - Official Inventory Report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#00796B'))),
                  pw.Text('Report Date: $currentDate', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
                ]
              ),
              pw.SizedBox(height: 5),
              pw.Divider(color: PdfColor.fromHex('#00796B'), thickness: 2),
              pw.SizedBox(height: 15),
              pw.TableHelper.fromTextArray(
                context: context,
                headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#00796B')),
                headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 12),
                cellStyle: const pw.TextStyle(fontSize: 11),
                headers: ['Item Name', 'Category', 'Total Qty', 'Consumed', 'Remaining', 'Expiry Date(s)'],
                data: reportData,
              ),
            ],
          )
        ];
      },
      footer: (pw.Context context) => pw.Container(alignment: pw.Alignment.centerRight, margin: const pw.EdgeInsets.only(top: 10), child: pw.Text('Generated via OT TRACKER PRO', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey)))
    ));
    await Printing.sharePdf(bytes: await pdf.save(), filename: 'OT_Tracker_Report.pdf');
  }

  // RESTORED ALERT BADGE WIDGETS 
  Widget _buildExplicitAlerts(Map<String, dynamic> item) {
    int totalQty = item['totalQty'] as int;
    int stockAlert = (item['stockAlert'] ?? 10) as int;
    int alertMonths = (item['expiryAlertMonths'] ?? 3) as int;
    String? nearestExpiry = item['nearestExpiry'];

    bool isOutOfStock = totalQty == 0;
    bool isLowStock = totalQty > 0 && totalQty <= stockAlert;
    bool isExpiring = false;
    bool isExpired = false;

    if (nearestExpiry != null && nearestExpiry != 'null') {
      try {
        DateTime expDate = DateTime.parse(nearestExpiry);
        int daysLeft = expDate.difference(DateTime.now()).inDays;
        if (daysLeft < 0) {
          isExpired = true;
        } else if (daysLeft <= (alertMonths * 30)) {
          isExpiring = true;
        }
      } catch (_) {}
    }

    if (!isOutOfStock && !isLowStock && !isExpiring && !isExpired) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (isOutOfStock)
            _buildBadge(Icons.block, 'Out of Stock', Colors.red.shade100, Colors.red.shade900),
          if (isLowStock) 
            _buildBadge(Icons.warning_amber_rounded, 'Low Stock', Colors.orange.shade100, Colors.orange.shade900),
          if (isExpired && !isOutOfStock) 
            _buildBadge(Icons.error_outline, 'Expired', Colors.red.shade100, Colors.red.shade900)
          else if (isExpiring && !isOutOfStock) 
            _buildBadge(Icons.timer_outlined, 'Expiring Soon', Colors.blue.shade100, Colors.blue.shade900),
        ],
      ),
    );
  }

  Widget _buildBadge(IconData icon, String text, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor)),
        ],
      ),
    );
  }

  void _showItemDetails(String itemName, String category, int stockAlert, int expiryAlertMonths) async {
    final dbHelper = DatabaseHelper.instance;
    List<Map<String, dynamic>> batches = await dbHelper.getBatches(itemName);
    final withdrawCtrl = TextEditingController();
    final patientIdCtrl = TextEditingController();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(builder: (BuildContext context, StateSetter setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.90,
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 20, right: 20, top: 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 50, height: 5, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)))),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(itemName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF00796B))),
                          Text(category, style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
                        ],
                      ),
                    ),
                    FloatingActionButton.small(
                      backgroundColor: const Color(0xFF00796B),
                      child: const Icon(Icons.add, color: Colors.white),
                      onPressed: () async {
                        Navigator.pop(context);
                        final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => ItemFormScreen(
                          preFillName: itemName, preFillCategory: category, preFillStockAlert: stockAlert, preFillExpiryAlert: expiryAlertMonths
                        )));
                        if (result == true) _loadData();
                      },
                    )
                  ],
                ),
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: patientIdCtrl,
                        decoration: InputDecoration(labelText: 'Patient ID (Optional)', filled: true, fillColor: Colors.grey.shade100, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.person_outline, size: 20)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: withdrawCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: 'Withdraw Qty', filled: true, fillColor: Colors.red.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    icon: const Icon(Icons.outbox),
                    label: const Text('FIFO Pull & Save to Audit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    onPressed: () async {
                      int amount = int.tryParse(withdrawCtrl.text) ?? 0;
                      if (amount > 0) {
                        await dbHelper.withdrawItemSmart(itemName, amount, patientIdCtrl.text.trim());
                        final updated = await dbHelper.getBatches(itemName);
                        setModalState(() => batches = updated);
                        withdrawCtrl.clear();
                        patientIdCtrl.clear();
                        _loadData();
                      }
                    },
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Active Batches:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.builder(
                    itemCount: batches.length,
                    itemBuilder: (context, index) {
                      final batch = batches[index];
                      final bool isZero = batch['quantity'] == 0;
                      return Card(
                        elevation: 0,
                        color: isZero ? Colors.grey.shade100 : Colors.teal.shade50,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: isZero ? Colors.grey.shade300 : Colors.teal.shade100)),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                          title: Text('Exp: ${batch['expiryDate']}  ${batch['lotNumber'] != '' && batch['lotNumber'] != null ? '| Lot: ${batch['lotNumber']}' : ''}', style: TextStyle(fontWeight: FontWeight.bold, decoration: isZero ? TextDecoration.lineThrough : null, color: isZero ? Colors.grey : Colors.black, fontSize: 14)),
                          subtitle: Text('Qty: ${batch['quantity']} / ${batch['initialQuantity']}', style: TextStyle(color: isZero ? Colors.grey : Colors.teal, fontWeight: FontWeight.bold, fontSize: 14)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, color: Colors.blueAccent),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => ItemFormScreen(batchToEdit: batch)));
                                  if (result == true) _loadData();
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () async {
                                  await dbHelper.deleteBatch(batch['id']);
                                  Navigator.pop(context);
                                  _loadData();
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 10, left: 16, right: 16, bottom: 16),
            decoration: const BoxDecoration(color: Color(0xFF80CBC4)),
            child: Column(
              children: [
                Row(
                  children: [
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: Container(width: 50, height: 50, color: Colors.white, child: Image.asset('assets/logo.jpg', fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.local_hospital, color: Colors.teal)))),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [Text('OT TRACKER PRO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Colors.black87)), Text('Noor Alyemen Eye Center', style: TextStyle(fontSize: 12, color: Colors.black87))])),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: Colors.black87),
                      onSelected: (value) {
                        if (value == 'pdf') _generatePdfReport();
                        if (value == 'backup') _backupDatabase();
                        if (value == 'audit') _viewAuditLog();
                      },
                      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                        const PopupMenuItem(value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf, color: Colors.red), title: Text('Export Report', style: TextStyle(fontSize: 14)), contentPadding: EdgeInsets.zero)),
                        const PopupMenuItem(value: 'audit', child: ListTile(leading: Icon(Icons.history, color: Colors.blue), title: Text('Audit Log', style: TextStyle(fontSize: 14)), contentPadding: EdgeInsets.zero)),
                        const PopupMenuItem(value: 'backup', child: ListTile(leading: Icon(Icons.cloud_download, color: Colors.teal), title: Text('Backup Database', style: TextStyle(fontSize: 14)), contentPadding: EdgeInsets.zero)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchCtrl,
                  onChanged: (value) => _applyFilters(),
                  decoration: InputDecoration(
                    hintText: 'Search name or barcode...',
                    prefixIcon: const Icon(Icons.search, color: Colors.black54),
                    suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF00796B)), onPressed: _scanBarcodeForSearch),
                    filled: true, fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _categories.map((category) {
                      bool isSelected = _selectedCategory == category;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(category, style: TextStyle(color: isSelected ? Colors.teal.shade900 : Colors.black87, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                          selected: isSelected, selectedColor: Colors.teal.shade100, backgroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: isSelected ? Colors.teal.shade300 : Colors.grey.shade300)),
                          onSelected: (selected) => setState(() { _selectedCategory = category; _applyFilters(); }),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _filteredItems.isEmpty ? const Center(child: Text('No items found.', style: TextStyle(color: Colors.black87))) : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _filteredItems.length,
              itemBuilder: (context, index) {
                final item = _filteredItems[index];
                final bool isZero = item['totalQty'] == 0;
                return Card(
                  elevation: 2, shadowColor: Colors.black12, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), margin: const EdgeInsets.symmetric(vertical: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _showItemDetails(item['name'], item['category'], item['stockAlert'], item['expiryAlertMonths']),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(height: 50, width: 50, decoration: BoxDecoration(color: isZero ? Colors.grey.shade200 : Colors.teal.shade50, borderRadius: BorderRadius.circular(12)), child: Icon(Icons.medication, color: isZero ? Colors.grey : const Color(0xFF00796B), size: 28)),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item['name'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isZero ? Colors.grey : Colors.black), maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Text(item['category'], style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                                _buildExplicitAlerts(item), // ALERTS RESTORED HERE!
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: isZero ? Colors.grey : const Color(0xFF00796B), borderRadius: BorderRadius.circular(12)), child: Text('${item['totalQty']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white))),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF80CBC4),
        onPressed: () async {
          String? passCategory = _selectedCategory == 'All' ? null : _selectedCategory;
          final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => ItemFormScreen(preFillCategory: passCategory)));
          if (result == true) _loadData();
        },
        child: const Icon(Icons.add, color: Colors.black87, size: 28),
      ),
    );
  }
}

// ==========================================
// 3. Add & Edit Form Screen
// ==========================================
class ItemFormScreen extends StatefulWidget {
  final String? preFillName;
  final String? preFillCategory;
  final int? preFillStockAlert;
  final int? preFillExpiryAlert;
  final Map<String, dynamic>? batchToEdit;

  const ItemFormScreen({super.key, this.preFillName, this.preFillCategory, this.preFillStockAlert, this.preFillExpiryAlert, this.batchToEdit});

  @override
  State<ItemFormScreen> createState() => _ItemFormScreenState();
}

class _ItemFormScreenState extends State<ItemFormScreen> {
  late TextEditingController _nameCtrl, _categoryCtrl, _barcodeCtrl, _lotCtrl, _stockAlertCtrl, _expiryAlertCtrl, _qtyCtrl, _expiryCtrl;

  @override
  void initState() {
    super.initState();
    bool isEdit = widget.batchToEdit != null;
    _nameCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['name'] : widget.preFillName ?? '');
    _categoryCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['category'] : widget.preFillCategory ?? '');
    _barcodeCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['barcode'] ?? '' : '');
    _lotCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['lotNumber'] ?? '' : '');
    _stockAlertCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['stockAlert'].toString() : widget.preFillStockAlert?.toString() ?? '10');
    _expiryAlertCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['expiryAlertMonths'].toString() : widget.preFillExpiryAlert?.toString() ?? '3');
    _qtyCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['quantity'].toString() : '');
    _expiryCtrl = TextEditingController(text: isEdit ? widget.batchToEdit!['expiryDate'] : '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _categoryCtrl.dispose(); _barcodeCtrl.dispose(); _lotCtrl.dispose();
    _qtyCtrl.dispose(); _expiryCtrl.dispose(); _stockAlertCtrl.dispose(); _expiryAlertCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanBarcode() async {
    try {
      var result = await BarcodeScanner.scan();
      if (result.type == ResultType.Barcode && result.rawContent.isNotEmpty && mounted) {
        setState(() => _barcodeCtrl.text = result.rawContent);
      }
    } catch (e) {}
  }

  Future<void> _saveData() async {
    final name = _nameCtrl.text.trim();
    final category = _categoryCtrl.text.trim();
    final barcode = _barcodeCtrl.text.trim();
    final lot = _lotCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text) ?? 0;
    final expiry = _expiryCtrl.text.trim();
    final sAlert = int.tryParse(_stockAlertCtrl.text) ?? 10;
    final eAlert = int.tryParse(_expiryAlertCtrl.text) ?? 3;

    if (name.isNotEmpty && qty >= 0 && expiry.isNotEmpty) {
      if (widget.batchToEdit != null) {
        await DatabaseHelper.instance.updateBatchFull(widget.batchToEdit!['id'], name, barcode, lot, qty, expiry, sAlert, eAlert);
      } else {
        final newItem = {
          'name': name,
          'category': category.isEmpty ? 'General' : category,
          'barcode': barcode,
          'lotNumber': lot,
          'initialQuantity': qty, 
          'quantity': qty,
          'stockAlert': sAlert,
          'expiryDate': expiry,
          'expiryAlertMonths': eAlert
        };
        await DatabaseHelper.instance.insertItem(newItem);
      }
      if (mounted) Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name, Quantity, and Expiry are required!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isEdit = widget.batchToEdit != null;
    bool isAddingBatch = widget.preFillName != null && !isEdit;
    String screenTitle = isEdit ? 'Edit Batch Data' : (isAddingBatch ? 'Add New Batch' : 'Add New Item');

    return Scaffold(
      appBar: AppBar(title: Text(screenTitle, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)), backgroundColor: const Color(0xFF00796B), iconTheme: const IconThemeData(color: Colors.white)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.grey.shade200, blurRadius: 10, spreadRadius: 2)]),
              child: Column(
                children: [
                  TextField(controller: _nameCtrl, enabled: !isAddingBatch && !isEdit, decoration: InputDecoration(labelText: 'Item Name *', prefixIcon: const Icon(Icons.label_important), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
                  const SizedBox(height: 15),
                  TextField(controller: _categoryCtrl, enabled: !isAddingBatch && !isEdit, decoration: InputDecoration(labelText: 'Category', prefixIcon: const Icon(Icons.category), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
                  const SizedBox(height: 15),
                  TextField(controller: _barcodeCtrl, enabled: !isAddingBatch && !isEdit, decoration: InputDecoration(labelText: 'Barcode (Optional)', prefixIcon: const Icon(Icons.qr_code), suffixIcon: IconButton(icon: const Icon(Icons.camera_alt, color: Color(0xFF00796B)), onPressed: _scanBarcode), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.grey.shade200, blurRadius: 10, spreadRadius: 2)]),
              child: Column(
                children: [
                  TextField(controller: _qtyCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Quantity *', prefixIcon: const Icon(Icons.format_list_numbered), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _expiryCtrl, readOnly: true, decoration: InputDecoration(labelText: 'Expiry Date *', prefixIcon: const Icon(Icons.calendar_today), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
                    onTap: () async {
                      DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2101));
                      if (picked != null) setState(() => _expiryCtrl.text = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}");
                    },
                  ),
                  const SizedBox(height: 15),
                  TextField(controller: _lotCtrl, decoration: InputDecoration(labelText: 'Lot / Batch Number (Optional)', prefixIcon: const Icon(Icons.inventory), filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
                ],
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity, height: 55,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00796B), elevation: 5, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))), 
                onPressed: _saveData, icon: const Icon(Icons.check_circle, color: Colors.white, size: 28), label: Text(isEdit ? 'Update Changes' : 'Save Details', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white))
              ),
            ),
          ],
        ),
      ),
    );
  }
}
