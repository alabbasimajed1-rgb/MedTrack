import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' hide context; // <--- الحل السحري لتصادم الأسماء

void main() => runApp(const OTTrackerApp());

class OTTrackerApp extends StatelessWidget {
  const OTTrackerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const InventoryHomePage(),
    );
  }
}

// ==========================================
// 1. Database Engine (Database Helper)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ot_tracker_v3.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final dbFilePath = join(dbPath, filePath);
    return await openDatabase(dbFilePath, version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT, quantity INTEGER, stockAlert INTEGER, expiryDate TEXT, expiryAlertMonths INTEGER)');
      await db.execute('CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, itemId INTEGER, date TEXT, type TEXT, amount INTEGER, note TEXT)');
    });
  }

  Future<int> insertItem(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('items', row);
  }

  Future<List<Map<String, dynamic>>> getGroupedItems() async {
    final db = await instance.database;
    return await db.rawQuery('SELECT name, category, SUM(quantity) as totalQty FROM items GROUP BY name ORDER BY name ASC');
  }

  Future<List<Map<String, dynamic>>> getBatches(String name) async {
    final db = await instance.database;
    return await db.query('items', where: 'name = ?', whereArgs: [name]);
  }

  Future<void> withdrawItemSmart(String itemName, int amountToWithdraw) async {
    final db = await instance.database;
    final batches = await db.query('items', where: 'name = ? AND quantity > 0', whereArgs: [itemName], orderBy: 'expiryDate ASC');

    int remainingToWithdraw = amountToWithdraw;

    for (var batch in batches) {
      if (remainingToWithdraw <= 0) break;

      int currentBatchQty = batch['quantity'] as int;
      int batchId = batch['id'] as int;

      if (currentBatchQty <= remainingToWithdraw) {
        await db.update('items', {'quantity': 0}, where: 'id = ?', whereArgs: [batchId]);
        remainingToWithdraw -= currentBatchQty;
      } else {
        await db.update('items', {'quantity': currentBatchQty - remainingToWithdraw}, where: 'id = ?', whereArgs: [batchId]);
        remainingToWithdraw = 0;
      }
    }
  }
}

// ==========================================
// 2. Main UI Logic (Inventory Home)
// ==========================================
class InventoryHomePage extends StatefulWidget {
  const InventoryHomePage({super.key});
  @override
  State<InventoryHomePage> createState() => _InventoryHomePageState();
}

class _InventoryHomePageState extends State<InventoryHomePage> {
  List<Map<String, dynamic>> _groupedItems = [];

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final data = await DatabaseHelper.instance.getGroupedItems();
    setState(() => _groupedItems = data);
  }

  void _showGroupedItemDetails(BuildContext context, String itemName, String category) async {
    final dbHelper = DatabaseHelper.instance;
    List<Map<String, dynamic>> batches = await dbHelper.getBatches(itemName);
    final withdrawCtrl = TextEditingController();

    if (!context.mounted) return; // حماية إضافية لمنع أخطاء الخادم

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 24),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(itemName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                    Text('Category: $category', style: const TextStyle(color: Colors.grey)),
                    const Divider(),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: withdrawCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Withdraw Amount', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                          onPressed: () async {
                            int amount = int.tryParse(withdrawCtrl.text) ?? 0;
                            if (amount > 0) {
                              await dbHelper.withdrawItemSmart(itemName, amount);
                              final updatedBatches = await dbHelper.getBatches(itemName);
                              setModalState(() => batches = updatedBatches);
                              withdrawCtrl.clear();
                              _loadItems(); 
                            }
                          },
                          child: const Text('Smart Withdraw'),
                        )
                      ],
                    ),
                    const SizedBox(height: 15),
                    const Text('Batch Details (FIFO):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: batches.length,
                        itemBuilder: (context, index) {
                          final batch = batches[index];
                          final bool isZero = batch['quantity'] == 0;
                          return Card(
                            color: isZero ? Colors.grey.shade100 : Colors.white,
                            elevation: isZero ? 0 : 1,
                            child: ListTile(
                              leading: Icon(Icons.inventory_2_outlined, color: isZero ? Colors.grey : Colors.teal),
                              title: Text('Expiry Date: ${batch['expiryDate']}', style: TextStyle(decoration: isZero ? TextDecoration.lineThrough : TextDecoration.none, color: isZero ? Colors.grey : Colors.black)),
                              trailing: Text('Qty: ${batch['quantity']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isZero ? Colors.red : Colors.teal)),
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
      appBar: AppBar(title: const Text('Inventory Pro - Grouped'), backgroundColor: Theme.of(context).colorScheme.inversePrimary),
      body: _groupedItems.isEmpty 
          ? const Center(child: Text('No items yet. Tap + to add.'))
          : ListView.builder(
              itemCount: _groupedItems.length,
              itemBuilder: (context, index) {
                final item = _groupedItems[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: ListTile(
                    title: Text(item['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Category: ${item['category']}'),
                    trailing: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(8)),
                      child: Text('Total Qty: ${item['totalQty']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    onTap: () => _showGroupedItemDetails(context, item['name'], item['category']),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => const AddItemScreen()));
          if (result == true) {
            _loadItems();
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ==========================================
// 3. Add New Item Screen
// ==========================================
class AddItemScreen extends StatefulWidget {
  const AddItemScreen({super.key});
  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _qtyCtrl.dispose();
    _expiryCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveItem() async {
    final name = _nameCtrl.text.trim();
    final category = _categoryCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text) ?? 0;
    final expiry = _expiryCtrl.text.trim();

    if (name.isNotEmpty && qty > 0 && expiry.isNotEmpty) {
      final newItem = {
        'name': name,
        'category': category.isEmpty ? 'General' : category,
        'quantity': qty,
        'expiryDate': expiry,
        'stockAlert': 10,
        'expiryAlertMonths': 3
      };
      await DatabaseHelper.instance.insertItem(newItem);
      if (mounted) Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all required fields correctly!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add New Item'), backgroundColor: Theme.of(context).colorScheme.inversePrimary),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Item Name *', prefixIcon: Icon(Icons.label), border: OutlineInputBorder())),
            const SizedBox(height: 15),
            TextField(controller: _categoryCtrl, decoration: const InputDecoration(labelText: 'Category (Optional)', prefixIcon: Icon(Icons.category), border: OutlineInputBorder())),
            const SizedBox(height: 15),
            TextField(controller: _qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity *', prefixIcon: Icon(Icons.format_list_numbered), border: OutlineInputBorder())),
            const SizedBox(height: 15),
            TextField(
              controller: _expiryCtrl,
              decoration: const InputDecoration(labelText: 'Expiry Date (YYYY-MM-DD) *', prefixIcon: Icon(Icons.calendar_today), border: OutlineInputBorder()),
              onTap: () async {
                DateTime? pickedDate = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2101));
                if (pickedDate != null) {
                  setState(() => _expiryCtrl.text = "${pickedDate.year}-${pickedDate.month.toString().padLeft(2, '0')}-${pickedDate.day.toString().padLeft(2, '0')}");
                }
              },
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white), onPressed: _saveItem, child: const Text('Save to Inventory', style: TextStyle(fontSize: 18))),
            ),
          ],
        ),
      ),
    );
  }
}
