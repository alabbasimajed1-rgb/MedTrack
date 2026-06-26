import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' hide context;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() => runApp(const OTTrackerProApp());

class OTTrackerProApp extends StatelessWidget {
  const OTTrackerProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OT-Tracker Pro',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00796B), // لون طبي/احترافي
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}

// ==========================================
// 1. Database Engine
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ot_tracker_v4.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT, quantity INTEGER, stockAlert INTEGER, expiryDate TEXT, expiryAlertMonths INTEGER)');
    });
  }

  Future<int> insertItem(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('items', row);
  }

  // تجميع الأصناف مع جلب أصغر تاريخ انتهاء وأعلى حد تنبيه
  Future<List<Map<String, dynamic>>> getGroupedItems() async {
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT name, category, 
             SUM(quantity) as totalQty, 
             MIN(expiryDate) as nearestExpiry, 
             MAX(stockAlert) as stockAlert, 
             MAX(expiryAlertMonths) as expiryAlertMonths
      FROM items 
      WHERE quantity > 0
      GROUP BY name 
      ORDER BY name ASC
    ''');
  }

  Future<List<Map<String, dynamic>>> getBatches(String name) async {
    final db = await instance.database;
    return await db.query('items', where: 'name = ? AND quantity > 0', whereArgs: [name], orderBy: 'expiryDate ASC');
  }

  Future<void> withdrawItemSmart(String itemName, int amountToWithdraw) async {
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
  }
}

// ==========================================
// 2. Main Dashboard (UI & Alerts)
// ==========================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data = await DatabaseHelper.instance.getGroupedItems();
    setState(() => _items = data);
  }

  // إنشاء ومشاركة تقرير PDF
  Future<void> _generatePdfReport() async {
    final pdf = pw.Document();
    
    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Inventory Status Report', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                context: context,
                headers: ['Item Name', 'Category', 'Quantity', 'Nearest Expiry'],
                data: _items.map((item) => [
                  item['name'].toString(),
                  item['category'].toString(),
                  item['totalQty'].toString(),
                  item['nearestExpiry'].toString()
                ]).toList(),
              ),
            ],
          );
        },
      ),
    );
    await Printing.sharePdf(bytes: await pdf.save(), filename: 'Inventory_Report.pdf');
  }

  // حساب حالة الإشعارات
  Widget _buildAlertIcons(Map<String, dynamic> item) {
    int totalQty = item['totalQty'] as int;
    int stockAlert = item['stockAlert'] as int;
    int alertMonths = item['expiryAlertMonths'] as int;
    String? nearestExpiry = item['nearestExpiry'];

    bool isLowStock = totalQty <= stockAlert;
    bool isExpiring = false;
    bool isExpired = false;

    if (nearestExpiry != null) {
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLowStock) const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
        if (isLowStock) const SizedBox(width: 4),
        if (isExpired) const Icon(Icons.block, color: Colors.red, size: 20)
        else if (isExpiring) const Icon(Icons.timer_outlined, color: Colors.orange, size: 20),
      ],
    );
  }

  void _showItemDetails(String itemName, String category, int stockAlert, int expiryAlertMonths) async {
    final dbHelper = DatabaseHelper.instance;
    List<Map<String, dynamic>> batches = await dbHelper.getBatches(itemName);
    final withdrawCtrl = TextEditingController();
    
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 24),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.75,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(itemName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF00796B)))),
                        // زر إضافة كمية لاحقة (دفعة جديدة)
                        IconButton(
                          icon: const Icon(Icons.add_circle, color: Colors.teal, size: 30),
                          tooltip: 'Add New Batch',
                          onPressed: () async {
                            Navigator.pop(context);
                            final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => AddItemScreen(
                              preFillName: itemName, 
                              preFillCategory: category, 
                              preFillStockAlert: stockAlert, 
                              preFillExpiryAlert: expiryAlertMonths
                            )));
                            if (result == true) _loadData();
                          },
                        )
                      ],
                    ),
                    Text('Category: $category', style: const TextStyle(color: Colors.grey)),
                    const Divider(),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: withdrawCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Withdraw Qty', 
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10)
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade400, 
                            foregroundColor: Colors.white, 
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                          ),
                          icon: const Icon(Icons.outbox),
                          label: const Text('FIFO Withdraw'),
                          onPressed: () async {
                            int amount = int.tryParse(withdrawCtrl.text) ?? 0;
                            if (amount > 0) {
                              await dbHelper.withdrawItemSmart(itemName, amount);
                              final updated = await dbHelper.getBatches(itemName);
                              setModalState(() => batches = updated);
                              withdrawCtrl.clear();
                              _loadData(); 
                            }
                          },
                        )
                      ],
                    ),
                    const SizedBox(height: 15),
                    const Text('Available Batches:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: batches.length,
                        itemBuilder: (context, index) {
                          final batch = batches[index];
                          return Card(
                            elevation: 2,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: const Icon(Icons.calendar_month, color: Colors.teal),
                              title: Text('Exp: ${batch['expiryDate']}'),
                              trailing: Text('Qty: ${batch['quantity']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal)),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory Pro', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
            tooltip: 'Export Report',
            onPressed: _items.isEmpty ? null : _generatePdfReport,
          )
        ],
      ),
      body: _items.isEmpty 
          ? const Center(child: Text('No items found. Tap + to add.', style: TextStyle(fontSize: 16, color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    title: Row(
                      children: [
                        Expanded(child: Text(item['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                        _buildAlertIcons(item),
                      ],
                    ),
                    subtitle: Text('Category: ${item['category']}'),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.teal.shade200)),
                      child: Text('${item['totalQty']}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal.shade700)),
                    ),
                    onTap: () => _showItemDetails(item['name'], item['category'], item['stockAlert'], item['expiryAlertMonths']),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => const AddItemScreen()));
          if (result == true) _loadData();
        },
        icon: const Icon(Icons.add),
        label: const Text('New Item'),
      ),
    );
  }
}

// ==========================================
// 3. Add New Item / Batch Screen
// ==========================================
class AddItemScreen extends StatefulWidget {
  final String? preFillName;
  final String? preFillCategory;
  final int? preFillStockAlert;
  final int? preFillExpiryAlert;

  const AddItemScreen({super.key, this.preFillName, this.preFillCategory, this.preFillStockAlert, this.preFillExpiryAlert});

  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _categoryCtrl;
  late TextEditingController _stockAlertCtrl;
  late TextEditingController _expiryAlertCtrl;
  final _qtyCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.preFillName ?? '');
    _categoryCtrl = TextEditingController(text: widget.preFillCategory ?? '');
    _stockAlertCtrl = TextEditingController(text: widget.preFillStockAlert?.toString() ?? '10');
    _expiryAlertCtrl = TextEditingController(text: widget.preFillExpiryAlert?.toString() ?? '3');
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _categoryCtrl.dispose(); _qtyCtrl.dispose(); _expiryCtrl.dispose(); _stockAlertCtrl.dispose(); _expiryAlertCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveItem() async {
    final name = _nameCtrl.text.trim();
    final category = _categoryCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text) ?? 0;
    final expiry = _expiryCtrl.text.trim();
    final sAlert = int.tryParse(_stockAlertCtrl.text) ?? 10;
    final eAlert = int.tryParse(_expiryAlertCtrl.text) ?? 3;

    if (name.isNotEmpty && qty > 0 && expiry.isNotEmpty) {
      final newItem = {
        'name': name,
        'category': category.isEmpty ? 'General' : category,
        'quantity': qty,
        'stockAlert': sAlert,
        'expiryDate': expiry,
        'expiryAlertMonths': eAlert
      };
      await DatabaseHelper.instance.insertItem(newItem);
      if (mounted) Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all required fields!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isAddingBatch = widget.preFillName != null;
    return Scaffold(
      appBar: AppBar(title: Text(isAddingBatch ? 'Add New Batch' : 'Add New Item'), backgroundColor: Theme.of(context).colorScheme.inversePrimary),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(controller: _nameCtrl, enabled: !isAddingBatch, decoration: const InputDecoration(labelText: 'Item Name *', prefixIcon: Icon(Icons.label), border: OutlineInputBorder())),
            const SizedBox(height: 15),
            TextField(controller: _categoryCtrl, enabled: !isAddingBatch, decoration: const InputDecoration(labelText: 'Category', prefixIcon: Icon(Icons.category), border: OutlineInputBorder())),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(child: TextField(controller: _stockAlertCtrl, enabled: !isAddingBatch, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Min Qty Alert', prefixIcon: Icon(Icons.warning), border: OutlineInputBorder()))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _expiryAlertCtrl, enabled: !isAddingBatch, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Months Alert', prefixIcon: Icon(Icons.timer), border: OutlineInputBorder()))),
              ],
            ),
            const Divider(height: 40, thickness: 2),
            TextField(controller: _qtyCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Batch Quantity *', prefixIcon: const Icon(Icons.format_list_numbered), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)))),
            const SizedBox(height: 15),
            TextField(
              controller: _expiryCtrl,
              readOnly: true,
              decoration: InputDecoration(labelText: 'Expiry Date *', prefixIcon: const Icon(Icons.calendar_today), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              onTap: () async {
                DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2101));
                if (picked != null) {
                  setState(() => _expiryCtrl.text = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}");
                }
              },
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00796B), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), 
                onPressed: _saveItem, 
                icon: const Icon(Icons.save),
                label: Text(isAddingBatch ? 'Save Batch' : 'Save Item', style: const TextStyle(fontSize: 18))
              ),
            ),
          ],
        ),
      ),
    );
  }
}
