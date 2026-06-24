import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Required for Clipboard functionality
import 'package:path_provider/path_provider.dart'; // Required for saving files
import 'package:sqflite/sqflite.dart';
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
    _database = await _initDB('medtrack_or.db');
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
  runApp(const MedTrackApp());
}

class MedTrackApp extends StatelessWidget {
  const MedTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MedTrack OR',
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
  List<Map<String, dynamic>> _inventoryItems = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshItems();
  }

  Future<void> _refreshItems() async {
    setState(() => _isLoading = true);
    final data = await DatabaseHelper.instance.getAllItems();
    setState(() {
      _inventoryItems = data;
      _isLoading = false;
    });
  }

  bool _isNearExpiry(String dateStr, int alertMonths) {
    if (dateStr == 'Not Set' || alertMonths == 0) return false;
    DateTime? expDate = DateTime.tryParse(dateStr);
    if (expDate == null) return false;
    final now = DateTime.now();
    return expDate.difference(now).inDays <= (alertMonths * 30);
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour}:${now.minute.toString().padLeft(2, '0')}";
  }

  // Function to Export Inventory Report to CSV (Excel compatible)
  Future<void> _exportInventoryReport() async {
    if (_inventoryItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data available to export.')),
      );
      return;
    }

    // Build the CSV String
    StringBuffer csvBuilder = StringBuffer();
    csvBuilder.writeln('Item Name,Current Quantity,Stock Alert Threshold,Expiry Date,Expiry Alert (Months)');

    for (var item in _inventoryItems) {
      csvBuilder.writeln('"${item['name']}",${item['quantity']},${item['stockAlert']},"${item['expiryDate']}",${item['expiryAlertMonths']}');
    }

    try {
      // Save to application private documents directory
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/OR_Inventory_Report.csv');
      await file.writeAsString(csvBuilder.toString());

      // Copy to clipboard for easy sharing via WhatsApp or Email instantly
      await Clipboard.setData(ClipboardData(text: csvBuilder.toString()));

      // Show success alert
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Report Exported!'),
          content: Text('1. Saved as Excel CSV file inside device storage.\n\n2. Copied to Clipboard! You can now paste it directly into WhatsApp, Email, or Google Sheets.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            )
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  void _showAddOrEditDialog({Map<String, dynamic>? existingItem}) {
    final nameCtrl = TextEditingController(text: existingItem?['name'] ?? '');
    final qtyCtrl = TextEditingController(text: existingItem != null ? existingItem['quantity'].toString() : '');
    final stockAlertCtrl = TextEditingController(text: existingItem != null ? existingItem['stockAlert'].toString() : '');
    final expiryCtrl = TextEditingController(text: existingItem?['expiryDate'] ?? '');
    final expiryAlertCtrl = TextEditingController(text: existingItem != null ? existingItem['expiryAlertMonths'].toString() : '');
    
    final bool isEditing = existingItem != null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16, right: 16, top: 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(isEditing ? 'Edit Item' : 'Add New Item', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Item Name', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()), enabled: !isEditing)),
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
                        'quantity': existingItem['quantity'], 
                        'stockAlert': int.tryParse(stockAlertCtrl.text) ?? 0,
                        'expiryDate': expiryCtrl.text.isEmpty ? 'Not Set' : expiryCtrl.text,
                        'expiryAlertMonths': int.tryParse(expiryAlertCtrl.text) ?? 0,
                      });
                    } else {
                      int initialQty = int.tryParse(qtyCtrl.text) ?? 0;
                      int itemId = await DatabaseHelper.instance.insertItem({
                        'name': nameCtrl.text,
                        'quantity': initialQty,
                        'stockAlert': int.tryParse(stockAlertCtrl.text) ?? 0,
                        'expiryDate': expiryCtrl.text.isEmpty ? 'Not Set' : expiryCtrl.text,
                        'expiryAlertMonths': int.tryParse(expiryAlertCtrl.text) ?? 0,
                      });
                      await DatabaseHelper.instance.insertTransaction({
                        'itemId': itemId,
                        'date': _getCurrentDate(),
                        'type': 'Initial Setup',
                        'amount': initialQty,
                        'note': 'First entry'
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
                        Expanded(child: Text(item['name'].toString().toUpperCase(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.teal))),
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.blueGrey),
                          tooltip: 'Edit Item Info',
                          onPressed: () {
                            Navigator.pop(context);
                            _showAddOrEditDialog(existingItem: item);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(12)),
                      child: Text('Current Qty: $currentQty', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    const Divider(height: 30, thickness: 2),
                    
                    TextField(
                      controller: actionCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Amount (e.g., 50)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.edit_note, color: Colors.teal)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                            icon: const Icon(Icons.remove_circle_outline),
                            label: const Text('Withdraw'),
                            onPressed: () async {
                              int amount = int.tryParse(actionCtrl.text) ?? 0;
                              if (amount > 0 && amount <= currentQty) {
                                currentQty -= amount;
                                await DatabaseHelper.instance.updateItem({...item, 'quantity': currentQty});
                                await DatabaseHelper.instance.insertTransaction({'itemId': item['id'], 'date': _getCurrentDate(), 'type': 'Withdrawal', 'amount': amount, 'note': 'OR Use'});
                                final updatedTrans = await DatabaseHelper.instance.getItemTransactions(item['id']);
                                setModalState(() => transactions = updatedTrans);
                                _refreshItems();
                                actionCtrl.clear();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade500, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                            icon: const Icon(Icons.add_circle_outline),
                            label: const Text('Restock'),
                            onPressed: () async {
                              int amount = int.tryParse(actionCtrl.text) ?? 0;
                              if (amount > 0) {
                                currentQty += amount;
                                await DatabaseHelper.instance.updateItem({...item, 'quantity': currentQty});
                                await DatabaseHelper.instance.insertTransaction({'itemId': item['id'], 'date': _getCurrentDate(), 'type': 'Restock', 'amount': amount, 'note': 'New Batch'});
                                final updatedTrans = await DatabaseHelper.instance.getItemTransactions(item['id']);
                                setModalState(() => transactions = updatedTrans);
                                _refreshItems();
                                actionCtrl.clear();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 40)),
                      icon: const Icon(Icons.analytics),
                      label: const Text('3-Month Consumption Report'),
                      onPressed: () {
                        int totalConsumed = 0;
                        final now = DateTime.now();
                        for (var t in transactions) {
                          if (t['type'] == 'Withdrawal') {
                            DateTime tDate = DateTime.parse(t['date'].split(' ')[0]);
                            if (now.difference(tDate).inDays <= 90) {
                              totalConsumed += t['amount'] as int;
                            }
                          }
                        }
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Consumption Report'),
                            content: Text('Total withdrawn in the last 90 days:\n\n$totalConsumed units.'),
                            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                          ),
                        );
                      },
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
                            elevation: 1,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(transIcon, color: iconColor),
                              title: Text(trans['type']),
                              subtitle: Text(trans['date']),
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
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('MedTrack - OR Vault', style: TextStyle(fontWeight: FontWeight.bold)),
        // Added the Export Action Button to the AppBar
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download, size: 28),
            tooltip: 'Export Report to Excel CSV',
            onPressed: _exportInventoryReport,
          ),
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator()) 
          : _inventoryItems.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.inventory_2_outlined, size: 100, color: Colors.teal),
                    SizedBox(height: 20),
                    Text('Database is empty', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    SizedBox(height: 10),
                    Text('Press (+) to start logging OR supplies'),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: _inventoryItems.length,
                itemBuilder: (context, index) {
                  final item = _inventoryItems[index];
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
                            const SizedBox(height: 4),
                            Text('Expiry: $expiryDateStr'),
                            if (isNearExpiry) const Text('⚠️ Expiring Soon!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                            if (isLowStock) const Text('⚠️ Low Stock Alert!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddOrEditDialog(),
        tooltip: 'Add Item',
        child: const Icon(Icons.add),
      ),
    );
  }
}
