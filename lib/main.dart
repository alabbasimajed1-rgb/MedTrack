import 'package:flutter/material.dart';

void main() {
  runApp(const MedTrackApp());
}

class MedTrackApp extends StatelessWidget {
  const MedTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MedTrack',
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
  final List<Map<String, dynamic>> _inventoryItems = [];

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _stockAlertController = TextEditingController();
  final TextEditingController _expiryController = TextEditingController();
  final TextEditingController _expiryAlertController = TextEditingController();

  // دالة الإضافة الجديدة (تؤسس سجل الحركات بأول عملية إضافة)
  void _addNewItem() {
    if (_nameController.text.isEmpty || _quantityController.text.isEmpty) {
      return;
    }

    int initialQty = int.tryParse(_quantityController.text) ?? 0;
    String currentDate = "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";

    setState(() {
      _inventoryItems.add({
        'name': _nameController.text,
        'quantity': initialQty,
        'stockAlert': int.tryParse(_stockAlertController.text) ?? 0,
        'expiryDate': _expiryController.text.isEmpty ? 'Not Set' : _expiryController.text,
        'expiryAlertMonths': int.tryParse(_expiryAlertController.text) ?? 0,
        // إنشاء سجل الحركات (Transactions) كقائمة داخل الصنف
        'transactions': [
          {'date': currentDate, 'type': 'Initial Setup', 'amount': initialQty, 'note': 'Initial Stock Added'}
        ],
      });
    });

    _nameController.clear();
    _quantityController.clear();
    _stockAlertController.clear();
    _expiryController.clear();
    _expiryAlertController.clear();

    Navigator.pop(context);
  }

  bool _isNearExpiry(String dateStr, int alertMonths) {
    if (dateStr == 'Not Set' || alertMonths == 0) return false;
    DateTime? expDate = DateTime.tryParse(dateStr);
    if (expDate == null) return false;

    final now = DateTime.now();
    final differenceInDays = expDate.difference(now).inDays;
    return differenceInDays <= (alertMonths * 30);
  }

  // نافذة إدارة الصنف (تسجيل الاستهلاك وعرض السجل)
  void _showItemDetails(int index) {
    final TextEditingController consumeController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        // نستخدم StatefulBuilder لتحديث النافذة المنبثقة فوراً عند الخصم
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final item = _inventoryItems[index];
            final List transactions = item['transactions'];

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 24,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.75, // أخذ 75% من الشاشة
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // عنوان الدواء والكمية الحالية
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          item['name'].toString().toUpperCase(),
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.teal),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.teal.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Current Qty: ${item['quantity']}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 30, thickness: 2),
                    
                    // قسم تسجيل الاستهلاك
                    const Text('Log Consumption (Withdrawal):', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: consumeController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Amount to use (e.g., 50)',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.remove_circle_outline, color: Colors.red),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade400,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                          ),
                          onPressed: () {
                            int consumeAmount = int.tryParse(consumeController.text) ?? 0;
                            if (consumeAmount > 0 && consumeAmount <= item['quantity']) {
                              String currentDate = "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";
                              
                              // تحديث الكمية الكلية وتحديث السجل
                              setModalState(() {
                                item['quantity'] -= consumeAmount;
                                transactions.insert(0, {
                                  'date': currentDate,
                                  'type': 'Withdrawal',
                                  'amount': consumeAmount,
                                  'note': 'Used in OR'
                                });
                              });
                              
                              // تحديث الشاشة الرئيسية بالخلف
                              setState(() {});
                              consumeController.clear();
                            }
                          },
                          child: const Text('Withdraw', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 20),
                    const Text('Transaction History:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 10),
                    
                    // عرض سجل الحركات
                    Expanded(
                      child: ListView.builder(
                        itemCount: transactions.length,
                        itemBuilder: (context, tIndex) {
                          final trans = transactions[tIndex];
                          final isWithdrawal = trans['type'] == 'Withdrawal';
                          return Card(
                            elevation: 1,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(
                                isWithdrawal ? Icons.arrow_downward : Icons.arrow_upward,
                                color: isWithdrawal ? Colors.red : Colors.green,
                              ),
                              title: Text(trans['type']),
                              subtitle: Text(trans['date']),
                              trailing: Text(
                                '${isWithdrawal ? '-' : '+'}${trans['amount']}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: isWithdrawal ? Colors.red : Colors.green,
                                ),
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
        title: const Text(
          'MedTrack - OR Vault',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _inventoryItems.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.inventory_2_outlined, size: 100, color: Colors.teal),
                  SizedBox(height: 20),
                  Text(
                    'Welcome to OR Vault',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 10),
                  Text('Press (+) to add a new item'),
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
                    side: BorderSide(
                      color: (isLowStock || isNearExpiry) ? Colors.red.shade300 : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: InkWell( // جعل البطاقة قابلة للضغط
                    onTap: () => _showItemDetails(index), // فتح نافذة التفاصيل عند الضغط
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: (isLowStock || isNearExpiry) ? Colors.red : Colors.teal,
                        child: Icon(
                          (isLowStock || isNearExpiry) ? Icons.warning_amber_rounded : Icons.medical_services,
                          color: Colors.white,
                        ),
                      ),
                      title: Text(
                        item['name'],
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text('Expiry: $expiryDateStr'),
                          if (isNearExpiry)
                            const Text('⚠️ Expiring Soon!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                          if (isLowStock)
                            const Text('⚠️ Low Stock Alert!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isLowStock ? Colors.red.shade50 : Colors.teal.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Qty: $qty',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isLowStock ? Colors.red : Colors.teal,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (context) {
              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 16,
                  right: 16,
                  top: 24,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Add New Item',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Item Name (e.g., Propofol)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _quantityController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Total Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _stockAlertController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Alert at Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _expiryController,
                        decoration: const InputDecoration(
                          labelText: 'Expiry Date (YYYY-MM-DD)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _expiryAlertController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Alert Before Expiry (Months)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                        ),
                        onPressed: _addNewItem,
                        child: const Text('Save to Vault', style: TextStyle(fontSize: 18)),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              );
            },
          );
        },
        tooltip: 'Add Item',
        child: const Icon(Icons.add),
      ),
    );
  }
}
