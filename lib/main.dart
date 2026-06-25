import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:async';

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
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT, quantity INTEGER, stockAlert INTEGER, expiryDate TEXT, expiryAlertMonths INTEGER)');
      await db.execute('CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, itemId INTEGER, date TEXT, type TEXT, amount INTEGER, note TEXT)');
    });
  }

  // Group items by name to show total quantity in the main list
  Future<List<Map<String, dynamic>>> getGroupedItems() async {
    final db = await instance.database;
    return await db.rawQuery('SELECT name, category, SUM(quantity) as totalQty FROM items GROUP BY name ORDER BY name ASC');
  }

  // Get specific batches for a selected item
  Future<List<Map<String, dynamic>>> getBatches(String name) async {
    final db = await instance.database;
    return await db.query('items', where: 'name = ?', whereArgs: [name]);
  }

  // Smart Withdrawal Function (FIFO: Deduct from the oldest expiry date first)
  Future<void> withdrawItemSmart(String itemName, int amountToWithdraw) async {
    final db = await instance.database;
    
    // Fetch all batches for this item, ordered by expiry date (oldest first)
    final batches = await db.query(
      'items', 
      where: 'name = ? AND quantity > 0', 
      whereArgs: [itemName],
      orderBy: 'expiryDate ASC' 
    );

    int remainingToWithdraw = amountToWithdraw;

    for (var batch in batches) {
      if (remainingToWithdraw <= 0) break; // Withdrawal complete

      int currentBatchQty = batch['quantity'] as int;
      int batchId = batch['id'] as int;

      if (currentBatchQty <= remainingToWithdraw) {
        // Deduct the entire batch quantity
        await db.update('items', {'quantity': 0}, where: 'id = ?', whereArgs: [batchId]);
        remainingToWithdraw -= currentBatchQty;
      } else {
        // Deduct only the required amount from this batch
        await db.update('items', {'quantity': currentBatchQty - remainingToWithdraw}, where: 'id = ?', whereArgs: [batchId]);
        remainingToWithdraw = 0; // Withdrawal complete
      }
    }
  }
}

// ==========================================
// 2. Main UI Logic
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom, 
                left: 16, right: 16, top: 24
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(itemName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                    Text('Category: $category', style: const TextStyle(color: Colors.grey)),
                    const Divider(),
                    
                    // Smart Withdrawal Input Section
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: withdrawCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Withdraw Amount', 
                              border: OutlineInputBorder()
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade400, 
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14)
                          ),
                          onPressed: () async {
                            int amount = int.tryParse(withdrawCtrl.text) ?? 0;
                            if (amount > 0) {
                              await dbHelper.withdrawItemSmart(itemName, amount);
                              final updatedBatches = await dbHelper.getBatches(itemName);
                              setModalState(() => batches = updatedBatches);
                              withdrawCtrl.clear();
                              _loadItems(); // Refresh main list
                            }
                          },
                          child: const Text('Smart Withdraw'),
                        )
                      ],
                    ),
                    const SizedBox(height: 15),
                    const Text('Batch Details (FIFO):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    
                    // List of all batches and expiry dates
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
                              leading: Icon(
                                Icons.inventory_2_outlined, 
                                color: isZero ? Colors.grey : Colors.teal
                              ),
                              title: Text(
                                'Expiry Date: ${batch['expiryDate']}',
                                style: TextStyle(
                                  decoration: isZero ? TextDecoration.lineThrough : TextDecoration.none,
                                  color: isZero ? Colors.grey : Colors.black
                                ),
                              ),
                              trailing: Text(
                                'Qty: ${batch['quantity']}', 
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold, 
                                  color: isZero ? Colors.red : Colors.teal
                                )
                              ),
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
        title: const Text('Inventory Pro - Grouped'), 
        backgroundColor: Theme.of(context).colorScheme.inversePrimary
      ),
      body: ListView.builder(
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
              onTap: () {
                _showGroupedItemDetails(context, item['name'], item['category']);
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Placeholder for adding new items
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
