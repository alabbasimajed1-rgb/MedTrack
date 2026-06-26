import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; 
import 'package:sqflite/sqflite.dart';
import 'package:share_plus/share_plus.dart'; 
import 'package:pdf/pdf.dart'; 
import 'package:pdf/widgets.dart' as pw; 
import 'dart:io';
import 'dart:async';

// ... (DatabaseHelper remains mostly the same, ensuring it can handle multiple rows per name)
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ot_tracker_pro.db');
    return _database!;
  }
  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    return await openDatabase('$dbPath/$filePath', version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT, quantity INTEGER, stockAlert INTEGER, expiryDate TEXT, expiryAlertMonths INTEGER)');
      await db.execute('CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, itemId INTEGER, date TEXT, type TEXT, amount INTEGER, note TEXT)');
    });
  }
  // Helper to get grouped items
  Future<List<Map<String, dynamic>>> getGroupedItems() async {
    final db = await instance.database;
    return await db.rawQuery('SELECT name, category, SUM(quantity) as totalQty FROM items GROUP BY name');
  }
  // Helper to get specific batches for a name
  Future<List<Map<String, dynamic>>> getBatches(String name) async {
    final db = await instance.database;
    return await db.query('items', where: 'name = ?', whereArgs: [name]);
  }
  // ... (insertItem, updateItem, deleteItem, etc. follow standard CRUD)
  Future<int> insertItem(Map<String, dynamic> item) => database.then((db) => db.insert('items', item));
  Future<int> updateItem(Map<String, dynamic> item) => database.then((db) => db.update('items', item, where: 'id = ?', whereArgs: [item['id']]));
  Future<int> deleteItem(int id) => database.then((db) => db.delete('items', where: 'id = ?', whereArgs: [id]));
}

// ... (Main UI - Implementation of Grouped Display)
// الجزء الأساسي في واجهة القائمة سيستخدم getGroupedItems()
// وعند الضغط، يتم تمرير اسم الصنف إلى شاشة التفاصيل التي تعرض Batches.
