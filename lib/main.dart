import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; 
import 'package:sqflite/sqflite.dart';
import 'package:share_plus/share_plus.dart'; 
import 'package:pdf/pdf.dart'; 
import 'package:pdf/widgets.dart' as pw; 
import 'dart:io';
import 'dart:async';

// ==========================================
// 1. Database Engine (Database Helper)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ot_tracker_vault.db'); // New DB for clean structure
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/$filePath';
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        stockAlert INTEGER NOT NULL,
        expiryDate TEXT NOT NULL,
        expiryAlertMonths INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        itemId INTEGER NOT NULL,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        amount INTEGER NOT NULL,
        note TEXT,
        FOREIGN KEY (itemId) REFERENCES items (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<int> insertItem(Map<String, dynamic> item) async {
    final db = await instance.database;
    return await db.insert('items', item);
  }

  Future<int> updateItem(Map<String, dynamic> item) async {
    final db = await instance.database;
    return await db.update('items', item, where: 'id = ?', whereArgs: [item['id']]);
  }

  Future<int> deleteItem(int id) async {
    final db = await instance.database;
    return await db.delete('items', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> insertTransaction(Map<String, dynamic> transaction) async {
    final db = await instance.database;
    return await db.insert('transactions', transaction);
  }

  Future<List<Map<String, dynamic>>> getAllItems() async {
    final db = await instance.database;
    return await db.query('items', orderBy: 'name ASC');
  }

  Future<List<Map<String, dynamic>>> getItemTransactions(int itemId) async {
    final db = await instance.database;
    return await db.query('transactions', where: 'itemId = ?', whereArgs: [itemId], orderBy: 'id DESC');
  }
}

// ==========================================
// 2. Main App UI & Logic
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OTTrackerApp());
}

class OTTrackerApp extends StatelessWidget {
  const OTTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OT-Tracker Pro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const InventoryHomePage(),
    );
  }
}

class InventoryHomePage extends StatefulWidget {
  const InventoryHomePage({super.key});

  @override
  State<InventoryHomePage> createState() => _InventoryHomePageState();
}

class _InventoryHomePageState extends State<InventoryHomePage> {
  List<Map<String, dynamic>> _allRawItems = []; // Master list from DB
  List<Map<String, dynamic>> _filteredItems = []; // List displayed after search/filter
  bool _isLoading = true;

  // Search and Category Filter controllers
  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedFilterCategory = 'All';

  // Available System Categories
  final List<String> _categories = ['Operating Room Supplies', 'Anesthesia Drugs & Supplies'];

  @override
  void initState() {
    super.initState();
    _refreshItems();
  }

  Future<void> _refreshItems() async {
    setState(() => _isLoading = true);
    final data = await DatabaseHelper.instance.getAllItems();
    setState(() {
      _allRawItems = data;
      _applySearchAndFilters();
      _isLoading = false;
    });
  }

  // خوارزمية تصفية البيانات الذكية للبحث والتصنيفات معاً
  void _applySearchAndFilters() {
    List<Map<String, dynamic>> results = [];
    final query = _searchCtrl.text.toLowerCase();

    for (var item in _allRawItems) {
      final matchesSearch = item['name'].toString().toLowerCase().contains(query);
      final matchesCategory = _selectedFilterCategory == 'All' || item['category'] == _selectedFilterCategory;

      if (matchesSearch && matchesCategory) {
        results.add(item);
      }
    }

    setState(() {
      _filteredItems = results;
    });
  }

  bool _isNearExpiry(String dateStr, int alertMonths) {
    if (dateStr == 'Not Set' || alertMonths == 0) return false;
    DateTime? expDate = DateTime.tryParse(dateStr);
    if (expDate == null) return false;
    return expDate.difference(DateTime.now()).inDays <= (alertMonths * 30);
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour}:${now.minute.toString().padLeft(2, '0')}";
  }

  Future<void> _exportPdfAndShare() async {
    if (_allRawItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No data available to export.')));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating PDF Document...')));

    final pdf = pw.Document();
    final tableHeaders = ['Item Name', 'Category', 'Total Qty', 'Consumed', 'Remaining', 'Expiry Date'];
    final tableData = <List<String>>[];

    for (var item in _allRawItems) {
      int itemId = item['id'];
      int remainingQty = item['quantity'];
      
      List<Map<String, dynamic>> transactions = await DatabaseHelper.instance.getItemTransactions(itemId);
      int consumedQty = 0;
      for (var t in transactions) {
        if (t['type'] == 'Withdrawal') {
          consumedQty += t['amount'] as int;
        }
      }

      tableData.add([
        item['name'].toString().toUpperCase(),
        item['category'].toString(),
        (remainingQty + consumedQty).toString(),
        consumedQty.toString(),
        remainingQty.toString(),
        item['expiryDate'],
      ]);
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape, // Landscape fits more columns perfectly
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Noor Alyemen Eye & E.N.T. Consulting Center', style: pw.TextStyle(fontSize: 14, color: PdfColors.grey700)),
                  pw.SizedBox(height: 4),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('OT-Tracker Pro - Official Inventory Report', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                      pw.Text('Report Date: ${_getCurrentDate()}', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
                    ]
                  ),
                ]
              )
            ),
            pw.SizedBox(height: 15),
            pw.TableHelper.fromTextArray(
              headers: tableHeaders,
              data: tableData,
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.teal),
              cellAlignment: pw.Alignment.centerLeft,
              cellStyle: const pw.TextStyle(fontSize: 10),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
            ),
            pw.SizedBox(height: 20),
            pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Generated via OT-Tracker Pro.', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey))),
          ];
        },
      ),
    );

    try {
      final output = await getTemporaryDirectory();
      final file = File('${output.path}/OT_Inventory_Report.pdf');
      await file.writeAsBytes(await pdf.save());

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Attached is the inventory backup summary from Noor Alyemen Eye & E.N.T. Consulting Center.',
        subject: 'OT-Tracker Pro Report - ${_getCurrentDate()}',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _showAddOrEditDialog({Map<String, dynamic>? existingItem}) {
    final nameCtrl = TextEditingController(text: existingItem?['name'] ?? '');
    final qtyCtrl = TextEditingController(text: existingItem != null ? existingItem['quantity'].toString() : '');
    final stockAlertCtrl = TextEditingController(text: existingItem != null ? existingItem['stockAlert'].toString() : '');
    final expiryCtrl = TextEditingController(text: existingItem?['expiryDate'] ?? '');
    final expiryAlertCtrl = TextEditingController(text: existingItem != null ? existingItem['expiryAlertMonths'].toString() : '');
    
    String itemCategory = existingItem?['category'] ?? _categories[0];
    final bool isEditing = existingItem != null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(isEditing ? 'Edit Vault Item' : 'Add New Vault Item', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    
                    DropdownButtonFormField<String>(
                      value: itemCategory,
                      decoration: const InputDecoration(labelText: 'Vault Category', border: OutlineInputBorder()),
                      items: _categories.map((String cat) {
                        return DropdownMenuItem<String>(value: cat, child: Text(cat));
                      }).toList(),
                      onChanged: (val) => setModalState(() => itemCategory = val!),
                    ),
                    const SizedBox(height: 12),
                    
                    TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Item Name', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()))),
                        const SizedBox(width: 12),
                        Expanded(child: TextField(controller: stockAlertCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stock Alert', border: OutlineInputBorder()))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: expiryCtrl, decoration: const InputDecoration(labelText: 'Expiry Date (YYYY-MM-DD)', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: expiryAlertCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Expiry Alert (Months)', border: OutlineInputBorder())),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
                      onPressed: () async {
                        if (nameCtrl.text.isEmpty) return;
                        
                        if (isEditing) {
                          await DatabaseHelper.instance.updateItem({
                            'id': existingItem['id'],
                            'name': nameCtrl.text,
                            'category': itemCategory,
                            'quantity': int.tryParse(qtyCtrl.text) ?? 0,
                            'stockAlert': int.tryParse(stockAlertCtrl.text) ?? 0,
                            'expiryDate': expiryCtrl.text.isEmpty ? 'Not Set' : expiryCtrl.text,
                            'expiryAlertMonths': int.tryParse(expiryAlertCtrl.text) ?? 0,
                          });
                        } else {
                          int initialQty = int.tryParse(qtyCtrl.text) ?? 0;
                          int itemId = await DatabaseHelper.instance.insertItem({
                            'name': nameCtrl.text,
                            'category': itemCategory,
                            'quantity': initialQty,
                            'stockAlert': int.tryParse(stockAlertCtrl.text) ?? 0,
                            'expiryDate': expiryCtrl.text.isEmpty ? 'Not Set' : expiryCtrl.text,
                            'expiryAlertMonths': int.tryParse(expiryAlertCtrl.text) ?? 0,
                          });
                          await DatabaseHelper.instance.insertTransaction({
                            'itemId': itemId, 'date': _getCurrentDate(), 'type': 'Initial Setup', 'amount': initialQty, 'note': 'First entry'
                          });
                        }
                        Navigator.pop(context);
                        _refreshItems();
                      },
                      child: Text(isEditing ? 'Save Changes' : 'Save to Vault', style: const TextStyle(fontSize: 18)),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showItemDetails(Map<String, dynamic> item) async {
    final actionCtrl = TextEditingController();
    List<Map<String, dynamic>> transactions = await DatabaseHelper.instance.getItemTransactions(item['id']);
    int currentQty = item['quantity'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 24),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.85,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item['name'].toString().toUpperCase(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                              Text('Category: ${item['category']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.edit, color: Colors.blueGrey), onPressed: () { Navigator.pop(context); _showAddOrEditDialog(existingItem: item); }),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete Item?'),
                                content: const Text('Are you sure you want to permanently delete this item?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                  TextButton(onPressed: () async { await DatabaseHelper.instance.deleteItem(item['id']); Navigator.pop(ctx); Navigator.pop(context); _refreshItems(); }, child: const Text('Delete', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(12)), child: Text('Current Qty: $currentQty', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    const Divider(height: 30, thickness: 2),
                    
                    TextField(controller: actionCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (e.g., 50)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.edit_note, color: Colors.teal))),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                            icon: const Icon(Icons.remove_circle_outline), label: const Text('Withdraw'),
                            onPressed: () async {
                              int amount = int.tryParse(actionCtrl.text) ?? 0;
                              if (amount > 0 && amount <= currentQty) {
                                currentQty -= amount;
                                await DatabaseHelper.instance.updateItem({...item, 'quantity': currentQty});
                                await DatabaseHelper.instance.insertTransaction({'itemId': item['id'], 'date': _getCurrentDate(), 'type': 'Withdrawal', 'amount': amount, 'note': 'OR Use'});
                                final updatedTrans = await DatabaseHelper.instance.getItemTransactions(item['id']);
                                setModalState(() => transactions = updatedTrans); _refreshItems(); actionCtrl.clear();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade500, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                            icon: const Icon(Icons.add_circle_outline), label: const Text('Restock'),
                            onPressed: () async {
                              int amount = int.tryParse(actionCtrl.text) ?? 0;
                              if (amount > 0) {
                                currentQty += amount;
                                await DatabaseHelper.instance.updateItem({...item, 'quantity': currentQty});
                                await DatabaseHelper.instance.insertTransaction({'itemId': item['id'], 'date': _getCurrentDate(), 'type': 'Restock', 'amount': amount, 'note': 'New Batch'});
                                final updatedTrans = await DatabaseHelper.instance.getItemTransactions(item['id']);
                                setModalState(() => transactions = updatedTrans); _refreshItems(); actionCtrl.clear();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text('Transaction History:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: transactions.length,
                        itemBuilder: (context, tIndex) {
                          final trans = transactions[tIndex];
                          final isWithdrawal = trans['type'] == 'Withdrawal';
                          final isInitial = trans['type'] == 'Initial Setup';
                          Color iconColor = isWithdrawal ? Colors.red : Colors.green;
                          IconData transIcon = isWithdrawal ? Icons.arrow_downward : (isInitial ? Icons.fiber_new : Icons.arrow_upward);

                          return Card(
                            elevation: 1, margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(transIcon, color: iconColor),
                              title: Text(trans['type']), subtitle: Text(trans['date']),
                              trailing: Text('${isWithdrawal ? '-' : '+'}${trans['amount']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: iconColor)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 85, // Extra height for logo and hospital title
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/logo.jpg',
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    width: 50, height: 50,
                    color: Colors.teal.shade700,
                    child: const Icon(Icons.local_hospital, color: Colors.white, size: 30),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('OT-Tracker Pro', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  Text(
                    'Noor Alyemen Eye & E.N.T. Consulting Center',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade800, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf, size: 28), tooltip: 'Export Official PDF Report', onPressed: _exportPdfAndShare),
        ],
      ),
      body: Column(
        children: [
          // ==========================================
          // لوحة تحكم التصفية والبحث الذكي
          // ==========================================
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.teal.shade50,
            child: Column(
              children: [
                // 1. شريط البحث
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search items inside theatre...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                  onChanged: (val) => _applySearchAndFilters(),
                ),
                const SizedBox(height: 10),
                
                // 2. أزرار الفلترة السريعة بحسب التصنيفات (Filter Chips)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _selectedFilterCategory == 'All',
                      onSelected: (bool selected) {
                        setState(() { _selectedFilterCategory = 'All'; _applySearchAndFilters(); });
                      },
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('OR Supplies'),
                      selected: _selectedFilterCategory == 'Operating Room Supplies',
                      onSelected: (bool selected) {
                        setState(() { _selectedFilterCategory = 'Operating Room Supplies'; _applySearchAndFilters(); });
                      },
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('Anesthesia'),
                      selected: _selectedFilterCategory == 'Anesthesia Drugs & Supplies',
                      onSelected: (bool selected) {
                        setState(() { _selectedFilterCategory = 'Anesthesia Drugs & Supplies'; _applySearchAndFilters(); });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // عرض القائمة المفلترة
          Expanded(
            child: _isLoading 
                ? const Center(child: CircularProgressIndicator()) 
                : _filteredItems.isEmpty
                  ? const Center(child: Text('No matching items found in the vault.'))
                  : ListView.builder(
                      itemCount: _filteredItems.length,
                      itemBuilder: (context, index) {
                        final item = _filteredItems[index];
                        final int qty = item['quantity'];
                        final int stockAlert = item['stockAlert'];
                        final String expiryDateStr = item['expiryDate'];
                        final int expiryAlertMonths = item['expiryAlertMonths'];

                        final bool isLowStock = qty <= stockAlert;
                        final bool isNearExpiry = _isNearExpiry(expiryDateStr, expiryAlertMonths);

                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: (isLowStock || isNearExpiry) ? Colors.red.shade300 : Colors.transparent, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: InkWell(
                            onTap: () => _showItemDetails(item),
                            borderRadius: BorderRadius.circular(12),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: (isLowStock || isNearExpiry) ? Colors.red : Colors.teal,
                                child: Icon((isLowStock || isNearExpiry) ? Icons.warning_amber_rounded : Icons.medical_services, color: Colors.white),
                              ),
                              title: Text(item['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Category: ${item['category']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                  const SizedBox(height: 2),
                                  Text('Expiry: $expiryDateStr', style: const TextStyle(fontSize: 13)),
                                  if (isNearExpiry) const Text('⚠️ Expiring Soon!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 11)),
                                  if (isLowStock) const Text('⚠️ Low Stock Alert!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 11)),
                                ],
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: isLowStock ? Colors.red.shade50 : Colors.teal.shade50, borderRadius: BorderRadius.circular(8)),
                                child: Text('Qty: $qty', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isLowStock ? Colors.red : Colors.teal)),
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
        onPressed: () => _showAddOrEditDialog(),
        tooltip: 'Add Item',
        child: const Icon(Icons.add),
      ),
    );
  }
}
