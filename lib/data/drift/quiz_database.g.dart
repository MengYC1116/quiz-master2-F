// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quiz_database.dart';

// ignore_for_file: type=lint
class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, DbSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  DbSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbSetting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class DbSetting extends DataClass implements Insertable<DbSetting> {
  final String key;
  final String value;
  const DbSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory DbSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  DbSetting copyWith({String? key, String? value}) =>
      DbSetting(key: key ?? this.key, value: value ?? this.value);
  DbSetting copyWithCompanion(SettingsCompanion data) {
    return DbSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<DbSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<DbSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TagsTable extends Tags with TableInfo<$TagsTable, DbTag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tags';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbTag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbTag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbTag(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
    );
  }

  @override
  $TagsTable createAlias(String alias) {
    return $TagsTable(attachedDatabase, alias);
  }
}

class DbTag extends DataClass implements Insertable<DbTag> {
  final String id;
  final String name;
  const DbTag({required this.id, required this.name});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    return map;
  }

  TagsCompanion toCompanion(bool nullToAbsent) {
    return TagsCompanion(id: Value(id), name: Value(name));
  }

  factory DbTag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbTag(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
    };
  }

  DbTag copyWith({String? id, String? name}) =>
      DbTag(id: id ?? this.id, name: name ?? this.name);
  DbTag copyWithCompanion(TagsCompanion data) {
    return DbTag(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbTag(')
          ..write('id: $id, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbTag && other.id == this.id && other.name == this.name);
}

class TagsCompanion extends UpdateCompanion<DbTag> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> rowid;
  const TagsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TagsCompanion.insert({
    required String id,
    required String name,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<DbTag> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TagsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? rowid,
  }) {
    return TagsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExamsTable extends Exams with TableInfo<$ExamsTable, DbExam> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExamsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<int> date = GeneratedColumn<int>(
    'date',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, date];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'exams';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbExam> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbExam map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbExam(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}date'],
      ),
    );
  }

  @override
  $ExamsTable createAlias(String alias) {
    return $ExamsTable(attachedDatabase, alias);
  }
}

class DbExam extends DataClass implements Insertable<DbExam> {
  final String id;
  final String name;
  final int? date;
  const DbExam({required this.id, required this.name, this.date});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || date != null) {
      map['date'] = Variable<int>(date);
    }
    return map;
  }

  ExamsCompanion toCompanion(bool nullToAbsent) {
    return ExamsCompanion(
      id: Value(id),
      name: Value(name),
      date: date == null && nullToAbsent ? const Value.absent() : Value(date),
    );
  }

  factory DbExam.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbExam(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      date: serializer.fromJson<int?>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'date': serializer.toJson<int?>(date),
    };
  }

  DbExam copyWith({
    String? id,
    String? name,
    Value<int?> date = const Value.absent(),
  }) => DbExam(
    id: id ?? this.id,
    name: name ?? this.name,
    date: date.present ? date.value : this.date,
  );
  DbExam copyWithCompanion(ExamsCompanion data) {
    return DbExam(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbExam(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, date);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbExam &&
          other.id == this.id &&
          other.name == this.name &&
          other.date == this.date);
}

class ExamsCompanion extends UpdateCompanion<DbExam> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> date;
  final Value<int> rowid;
  const ExamsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ExamsCompanion.insert({
    required String id,
    required String name,
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<DbExam> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? date,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (date != null) 'date': date,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ExamsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int?>? date,
    Value<int>? rowid,
  }) {
    return ExamsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      date: date ?? this.date,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (date.present) {
      map['date'] = Variable<int>(date.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExamsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('date: $date, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnowledgePointsTable extends KnowledgePoints
    with TableInfo<$KnowledgePointsTable, DbKnowledgePoint> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnowledgePointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterMeta = const VerificationMeta(
    'chapter',
  );
  @override
  late final GeneratedColumn<String> chapter = GeneratedColumn<String>(
    'chapter',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, subjectId, chapter, name];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'knowledge_points';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbKnowledgePoint> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('chapter')) {
      context.handle(
        _chapterMeta,
        chapter.isAcceptableOrUnknown(data['chapter']!, _chapterMeta),
      );
    } else if (isInserting) {
      context.missing(_chapterMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbKnowledgePoint map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbKnowledgePoint(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      chapter: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
    );
  }

  @override
  $KnowledgePointsTable createAlias(String alias) {
    return $KnowledgePointsTable(attachedDatabase, alias);
  }
}

class DbKnowledgePoint extends DataClass
    implements Insertable<DbKnowledgePoint> {
  final String id;
  final String subjectId;
  final String chapter;
  final String name;
  const DbKnowledgePoint({
    required this.id,
    required this.subjectId,
    required this.chapter,
    required this.name,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['subject_id'] = Variable<String>(subjectId);
    map['chapter'] = Variable<String>(chapter);
    map['name'] = Variable<String>(name);
    return map;
  }

  KnowledgePointsCompanion toCompanion(bool nullToAbsent) {
    return KnowledgePointsCompanion(
      id: Value(id),
      subjectId: Value(subjectId),
      chapter: Value(chapter),
      name: Value(name),
    );
  }

  factory DbKnowledgePoint.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbKnowledgePoint(
      id: serializer.fromJson<String>(json['id']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      chapter: serializer.fromJson<String>(json['chapter']),
      name: serializer.fromJson<String>(json['name']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'subjectId': serializer.toJson<String>(subjectId),
      'chapter': serializer.toJson<String>(chapter),
      'name': serializer.toJson<String>(name),
    };
  }

  DbKnowledgePoint copyWith({
    String? id,
    String? subjectId,
    String? chapter,
    String? name,
  }) => DbKnowledgePoint(
    id: id ?? this.id,
    subjectId: subjectId ?? this.subjectId,
    chapter: chapter ?? this.chapter,
    name: name ?? this.name,
  );
  DbKnowledgePoint copyWithCompanion(KnowledgePointsCompanion data) {
    return DbKnowledgePoint(
      id: data.id.present ? data.id.value : this.id,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      chapter: data.chapter.present ? data.chapter.value : this.chapter,
      name: data.name.present ? data.name.value : this.name,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbKnowledgePoint(')
          ..write('id: $id, ')
          ..write('subjectId: $subjectId, ')
          ..write('chapter: $chapter, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, subjectId, chapter, name);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbKnowledgePoint &&
          other.id == this.id &&
          other.subjectId == this.subjectId &&
          other.chapter == this.chapter &&
          other.name == this.name);
}

class KnowledgePointsCompanion extends UpdateCompanion<DbKnowledgePoint> {
  final Value<String> id;
  final Value<String> subjectId;
  final Value<String> chapter;
  final Value<String> name;
  final Value<int> rowid;
  const KnowledgePointsCompanion({
    this.id = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.chapter = const Value.absent(),
    this.name = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnowledgePointsCompanion.insert({
    required String id,
    required String subjectId,
    required String chapter,
    required String name,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       subjectId = Value(subjectId),
       chapter = Value(chapter),
       name = Value(name);
  static Insertable<DbKnowledgePoint> custom({
    Expression<String>? id,
    Expression<String>? subjectId,
    Expression<String>? chapter,
    Expression<String>? name,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (subjectId != null) 'subject_id': subjectId,
      if (chapter != null) 'chapter': chapter,
      if (name != null) 'name': name,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnowledgePointsCompanion copyWith({
    Value<String>? id,
    Value<String>? subjectId,
    Value<String>? chapter,
    Value<String>? name,
    Value<int>? rowid,
  }) {
    return KnowledgePointsCompanion(
      id: id ?? this.id,
      subjectId: subjectId ?? this.subjectId,
      chapter: chapter ?? this.chapter,
      name: name ?? this.name,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (chapter.present) {
      map['chapter'] = Variable<String>(chapter.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnowledgePointsCompanion(')
          ..write('id: $id, ')
          ..write('subjectId: $subjectId, ')
          ..write('chapter: $chapter, ')
          ..write('name: $name, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FoldersTable extends Folders with TableInfo<$FoldersTable, DbFolder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    subjectId,
    parentId,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbFolder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbFolder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbFolder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $FoldersTable createAlias(String alias) {
    return $FoldersTable(attachedDatabase, alias);
  }
}

class DbFolder extends DataClass implements Insertable<DbFolder> {
  final String id;
  final String name;
  final String subjectId;
  final String? parentId;
  final int sortOrder;
  const DbFolder({
    required this.id,
    required this.name,
    required this.subjectId,
    this.parentId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['subject_id'] = Variable<String>(subjectId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  FoldersCompanion toCompanion(bool nullToAbsent) {
    return FoldersCompanion(
      id: Value(id),
      name: Value(name),
      subjectId: Value(subjectId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
    );
  }

  factory DbFolder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbFolder(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'subjectId': serializer.toJson<String>(subjectId),
      'parentId': serializer.toJson<String?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  DbFolder copyWith({
    String? id,
    String? name,
    String? subjectId,
    Value<String?> parentId = const Value.absent(),
    int? sortOrder,
  }) => DbFolder(
    id: id ?? this.id,
    name: name ?? this.name,
    subjectId: subjectId ?? this.subjectId,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  DbFolder copyWithCompanion(FoldersCompanion data) {
    return DbFolder(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbFolder(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('subjectId: $subjectId, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, subjectId, parentId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbFolder &&
          other.id == this.id &&
          other.name == this.name &&
          other.subjectId == this.subjectId &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder);
}

class FoldersCompanion extends UpdateCompanion<DbFolder> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> subjectId;
  final Value<String?> parentId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const FoldersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FoldersCompanion.insert({
    required String id,
    required String name,
    required String subjectId,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       subjectId = Value(subjectId);
  static Insertable<DbFolder> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? subjectId,
    Expression<String>? parentId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (subjectId != null) 'subject_id': subjectId,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FoldersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? subjectId,
    Value<String?>? parentId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return FoldersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      subjectId: subjectId ?? this.subjectId,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FoldersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('subjectId: $subjectId, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SubjectsTable extends Subjects
    with TableInfo<$SubjectsTable, DbSubject> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SubjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<int> color = GeneratedColumn<int>(
    'color',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverStyleMeta = const VerificationMeta(
    'coverStyle',
  );
  @override
  late final GeneratedColumn<String> coverStyle = GeneratedColumn<String>(
    'cover_style',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('plain'),
  );
  static const VerificationMeta _coverColorMeta = const VerificationMeta(
    'coverColor',
  );
  @override
  late final GeneratedColumn<String> coverColor = GeneratedColumn<String>(
    'cover_color',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('blue'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    color,
    coverStyle,
    coverColor,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'subjects';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbSubject> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('cover_style')) {
      context.handle(
        _coverStyleMeta,
        coverStyle.isAcceptableOrUnknown(data['cover_style']!, _coverStyleMeta),
      );
    }
    if (data.containsKey('cover_color')) {
      context.handle(
        _coverColorMeta,
        coverColor.isAcceptableOrUnknown(data['cover_color']!, _coverColorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbSubject map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbSubject(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color'],
      )!,
      coverStyle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_style'],
      )!,
      coverColor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_color'],
      )!,
    );
  }

  @override
  $SubjectsTable createAlias(String alias) {
    return $SubjectsTable(attachedDatabase, alias);
  }
}

class DbSubject extends DataClass implements Insertable<DbSubject> {
  final String id;
  final String name;
  final int color;
  final String coverStyle;
  final String coverColor;
  const DbSubject({
    required this.id,
    required this.name,
    required this.color,
    required this.coverStyle,
    required this.coverColor,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['color'] = Variable<int>(color);
    map['cover_style'] = Variable<String>(coverStyle);
    map['cover_color'] = Variable<String>(coverColor);
    return map;
  }

  SubjectsCompanion toCompanion(bool nullToAbsent) {
    return SubjectsCompanion(
      id: Value(id),
      name: Value(name),
      color: Value(color),
      coverStyle: Value(coverStyle),
      coverColor: Value(coverColor),
    );
  }

  factory DbSubject.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbSubject(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      color: serializer.fromJson<int>(json['color']),
      coverStyle: serializer.fromJson<String>(json['coverStyle']),
      coverColor: serializer.fromJson<String>(json['coverColor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'color': serializer.toJson<int>(color),
      'coverStyle': serializer.toJson<String>(coverStyle),
      'coverColor': serializer.toJson<String>(coverColor),
    };
  }

  DbSubject copyWith({
    String? id,
    String? name,
    int? color,
    String? coverStyle,
    String? coverColor,
  }) => DbSubject(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    coverStyle: coverStyle ?? this.coverStyle,
    coverColor: coverColor ?? this.coverColor,
  );
  DbSubject copyWithCompanion(SubjectsCompanion data) {
    return DbSubject(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      color: data.color.present ? data.color.value : this.color,
      coverStyle: data.coverStyle.present
          ? data.coverStyle.value
          : this.coverStyle,
      coverColor: data.coverColor.present
          ? data.coverColor.value
          : this.coverColor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbSubject(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('coverStyle: $coverStyle, ')
          ..write('coverColor: $coverColor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, color, coverStyle, coverColor);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbSubject &&
          other.id == this.id &&
          other.name == this.name &&
          other.color == this.color &&
          other.coverStyle == this.coverStyle &&
          other.coverColor == this.coverColor);
}

class SubjectsCompanion extends UpdateCompanion<DbSubject> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> color;
  final Value<String> coverStyle;
  final Value<String> coverColor;
  final Value<int> rowid;
  const SubjectsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.color = const Value.absent(),
    this.coverStyle = const Value.absent(),
    this.coverColor = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SubjectsCompanion.insert({
    required String id,
    required String name,
    required int color,
    this.coverStyle = const Value.absent(),
    this.coverColor = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       color = Value(color);
  static Insertable<DbSubject> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? color,
    Expression<String>? coverStyle,
    Expression<String>? coverColor,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (color != null) 'color': color,
      if (coverStyle != null) 'cover_style': coverStyle,
      if (coverColor != null) 'cover_color': coverColor,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SubjectsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? color,
    Value<String>? coverStyle,
    Value<String>? coverColor,
    Value<int>? rowid,
  }) {
    return SubjectsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      coverStyle: coverStyle ?? this.coverStyle,
      coverColor: coverColor ?? this.coverColor,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (color.present) {
      map['color'] = Variable<int>(color.value);
    }
    if (coverStyle.present) {
      map['cover_style'] = Variable<String>(coverStyle.value);
    }
    if (coverColor.present) {
      map['cover_color'] = Variable<String>(coverColor.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SubjectsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('coverStyle: $coverStyle, ')
          ..write('coverColor: $coverColor, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecentTasksTable extends RecentTasks
    with TableInfo<$RecentTasksTable, DbRecentTask> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecentTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY CHECK (id = 1)',
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, kind, subjectId, title, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recent_tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbRecentTask> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbRecentTask map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbRecentTask(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $RecentTasksTable createAlias(String alias) {
    return $RecentTasksTable(attachedDatabase, alias);
  }
}

class DbRecentTask extends DataClass implements Insertable<DbRecentTask> {
  final int id;
  final String kind;
  final String subjectId;
  final String title;
  final int updatedAt;
  const DbRecentTask({
    required this.id,
    required this.kind,
    required this.subjectId,
    required this.title,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['kind'] = Variable<String>(kind);
    map['subject_id'] = Variable<String>(subjectId);
    map['title'] = Variable<String>(title);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  RecentTasksCompanion toCompanion(bool nullToAbsent) {
    return RecentTasksCompanion(
      id: Value(id),
      kind: Value(kind),
      subjectId: Value(subjectId),
      title: Value(title),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbRecentTask.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbRecentTask(
      id: serializer.fromJson<int>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      title: serializer.fromJson<String>(json['title']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'kind': serializer.toJson<String>(kind),
      'subjectId': serializer.toJson<String>(subjectId),
      'title': serializer.toJson<String>(title),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DbRecentTask copyWith({
    int? id,
    String? kind,
    String? subjectId,
    String? title,
    int? updatedAt,
  }) => DbRecentTask(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    subjectId: subjectId ?? this.subjectId,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbRecentTask copyWithCompanion(RecentTasksCompanion data) {
    return DbRecentTask(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      title: data.title.present ? data.title.value : this.title,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbRecentTask(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectId: $subjectId, ')
          ..write('title: $title, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, kind, subjectId, title, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbRecentTask &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.subjectId == this.subjectId &&
          other.title == this.title &&
          other.updatedAt == this.updatedAt);
}

class RecentTasksCompanion extends UpdateCompanion<DbRecentTask> {
  final Value<int> id;
  final Value<String> kind;
  final Value<String> subjectId;
  final Value<String> title;
  final Value<int> updatedAt;
  const RecentTasksCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.title = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  RecentTasksCompanion.insert({
    this.id = const Value.absent(),
    required String kind,
    required String subjectId,
    required String title,
    required int updatedAt,
  }) : kind = Value(kind),
       subjectId = Value(subjectId),
       title = Value(title),
       updatedAt = Value(updatedAt);
  static Insertable<DbRecentTask> custom({
    Expression<int>? id,
    Expression<String>? kind,
    Expression<String>? subjectId,
    Expression<String>? title,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (subjectId != null) 'subject_id': subjectId,
      if (title != null) 'title': title,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  RecentTasksCompanion copyWith({
    Value<int>? id,
    Value<String>? kind,
    Value<String>? subjectId,
    Value<String>? title,
    Value<int>? updatedAt,
  }) {
    return RecentTasksCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      subjectId: subjectId ?? this.subjectId,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecentTasksCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectId: $subjectId, ')
          ..write('title: $title, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $RecentlyViewedQuestionsTable extends RecentlyViewedQuestions
    with TableInfo<$RecentlyViewedQuestionsTable, RecentlyViewedQuestion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecentlyViewedQuestionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _viewedAtMeta = const VerificationMeta(
    'viewedAt',
  );
  @override
  late final GeneratedColumn<int> viewedAt = GeneratedColumn<int>(
    'viewed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [questionId, viewedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recently_viewed_questions';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecentlyViewedQuestion> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('viewed_at')) {
      context.handle(
        _viewedAtMeta,
        viewedAt.isAcceptableOrUnknown(data['viewed_at']!, _viewedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_viewedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {questionId};
  @override
  RecentlyViewedQuestion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecentlyViewedQuestion(
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      viewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}viewed_at'],
      )!,
    );
  }

  @override
  $RecentlyViewedQuestionsTable createAlias(String alias) {
    return $RecentlyViewedQuestionsTable(attachedDatabase, alias);
  }
}

class RecentlyViewedQuestion extends DataClass
    implements Insertable<RecentlyViewedQuestion> {
  final String questionId;
  final int viewedAt;
  const RecentlyViewedQuestion({
    required this.questionId,
    required this.viewedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['question_id'] = Variable<String>(questionId);
    map['viewed_at'] = Variable<int>(viewedAt);
    return map;
  }

  RecentlyViewedQuestionsCompanion toCompanion(bool nullToAbsent) {
    return RecentlyViewedQuestionsCompanion(
      questionId: Value(questionId),
      viewedAt: Value(viewedAt),
    );
  }

  factory RecentlyViewedQuestion.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecentlyViewedQuestion(
      questionId: serializer.fromJson<String>(json['questionId']),
      viewedAt: serializer.fromJson<int>(json['viewedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'questionId': serializer.toJson<String>(questionId),
      'viewedAt': serializer.toJson<int>(viewedAt),
    };
  }

  RecentlyViewedQuestion copyWith({String? questionId, int? viewedAt}) =>
      RecentlyViewedQuestion(
        questionId: questionId ?? this.questionId,
        viewedAt: viewedAt ?? this.viewedAt,
      );
  RecentlyViewedQuestion copyWithCompanion(
    RecentlyViewedQuestionsCompanion data,
  ) {
    return RecentlyViewedQuestion(
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      viewedAt: data.viewedAt.present ? data.viewedAt.value : this.viewedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecentlyViewedQuestion(')
          ..write('questionId: $questionId, ')
          ..write('viewedAt: $viewedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(questionId, viewedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentlyViewedQuestion &&
          other.questionId == this.questionId &&
          other.viewedAt == this.viewedAt);
}

class RecentlyViewedQuestionsCompanion
    extends UpdateCompanion<RecentlyViewedQuestion> {
  final Value<String> questionId;
  final Value<int> viewedAt;
  final Value<int> rowid;
  const RecentlyViewedQuestionsCompanion({
    this.questionId = const Value.absent(),
    this.viewedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecentlyViewedQuestionsCompanion.insert({
    required String questionId,
    required int viewedAt,
    this.rowid = const Value.absent(),
  }) : questionId = Value(questionId),
       viewedAt = Value(viewedAt);
  static Insertable<RecentlyViewedQuestion> custom({
    Expression<String>? questionId,
    Expression<int>? viewedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (questionId != null) 'question_id': questionId,
      if (viewedAt != null) 'viewed_at': viewedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecentlyViewedQuestionsCompanion copyWith({
    Value<String>? questionId,
    Value<int>? viewedAt,
    Value<int>? rowid,
  }) {
    return RecentlyViewedQuestionsCompanion(
      questionId: questionId ?? this.questionId,
      viewedAt: viewedAt ?? this.viewedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (viewedAt.present) {
      map['viewed_at'] = Variable<int>(viewedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecentlyViewedQuestionsCompanion(')
          ..write('questionId: $questionId, ')
          ..write('viewedAt: $viewedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReviewHistoryTable extends ReviewHistory
    with TableInfo<$ReviewHistoryTable, DbReviewHistory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReviewHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultMeta = const VerificationMeta('result');
  @override
  late final GeneratedColumn<String> result = GeneratedColumn<String>(
    'result',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reviewedAtMeta = const VerificationMeta(
    'reviewedAt',
  );
  @override
  late final GeneratedColumn<int> reviewedAt = GeneratedColumn<int>(
    'reviewed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, questionId, result, reviewedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'review_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbReviewHistory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('result')) {
      context.handle(
        _resultMeta,
        result.isAcceptableOrUnknown(data['result']!, _resultMeta),
      );
    } else if (isInserting) {
      context.missing(_resultMeta);
    }
    if (data.containsKey('reviewed_at')) {
      context.handle(
        _reviewedAtMeta,
        reviewedAt.isAcceptableOrUnknown(data['reviewed_at']!, _reviewedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_reviewedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbReviewHistory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbReviewHistory(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      result: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result'],
      )!,
      reviewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reviewed_at'],
      )!,
    );
  }

  @override
  $ReviewHistoryTable createAlias(String alias) {
    return $ReviewHistoryTable(attachedDatabase, alias);
  }
}

class DbReviewHistory extends DataClass implements Insertable<DbReviewHistory> {
  final int id;
  final String questionId;
  final String result;
  final int reviewedAt;
  const DbReviewHistory({
    required this.id,
    required this.questionId,
    required this.result,
    required this.reviewedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['question_id'] = Variable<String>(questionId);
    map['result'] = Variable<String>(result);
    map['reviewed_at'] = Variable<int>(reviewedAt);
    return map;
  }

  ReviewHistoryCompanion toCompanion(bool nullToAbsent) {
    return ReviewHistoryCompanion(
      id: Value(id),
      questionId: Value(questionId),
      result: Value(result),
      reviewedAt: Value(reviewedAt),
    );
  }

  factory DbReviewHistory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbReviewHistory(
      id: serializer.fromJson<int>(json['id']),
      questionId: serializer.fromJson<String>(json['questionId']),
      result: serializer.fromJson<String>(json['result']),
      reviewedAt: serializer.fromJson<int>(json['reviewedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'questionId': serializer.toJson<String>(questionId),
      'result': serializer.toJson<String>(result),
      'reviewedAt': serializer.toJson<int>(reviewedAt),
    };
  }

  DbReviewHistory copyWith({
    int? id,
    String? questionId,
    String? result,
    int? reviewedAt,
  }) => DbReviewHistory(
    id: id ?? this.id,
    questionId: questionId ?? this.questionId,
    result: result ?? this.result,
    reviewedAt: reviewedAt ?? this.reviewedAt,
  );
  DbReviewHistory copyWithCompanion(ReviewHistoryCompanion data) {
    return DbReviewHistory(
      id: data.id.present ? data.id.value : this.id,
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      result: data.result.present ? data.result.value : this.result,
      reviewedAt: data.reviewedAt.present
          ? data.reviewedAt.value
          : this.reviewedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbReviewHistory(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('result: $result, ')
          ..write('reviewedAt: $reviewedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, questionId, result, reviewedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbReviewHistory &&
          other.id == this.id &&
          other.questionId == this.questionId &&
          other.result == this.result &&
          other.reviewedAt == this.reviewedAt);
}

class ReviewHistoryCompanion extends UpdateCompanion<DbReviewHistory> {
  final Value<int> id;
  final Value<String> questionId;
  final Value<String> result;
  final Value<int> reviewedAt;
  const ReviewHistoryCompanion({
    this.id = const Value.absent(),
    this.questionId = const Value.absent(),
    this.result = const Value.absent(),
    this.reviewedAt = const Value.absent(),
  });
  ReviewHistoryCompanion.insert({
    this.id = const Value.absent(),
    required String questionId,
    required String result,
    required int reviewedAt,
  }) : questionId = Value(questionId),
       result = Value(result),
       reviewedAt = Value(reviewedAt);
  static Insertable<DbReviewHistory> custom({
    Expression<int>? id,
    Expression<String>? questionId,
    Expression<String>? result,
    Expression<int>? reviewedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (questionId != null) 'question_id': questionId,
      if (result != null) 'result': result,
      if (reviewedAt != null) 'reviewed_at': reviewedAt,
    });
  }

  ReviewHistoryCompanion copyWith({
    Value<int>? id,
    Value<String>? questionId,
    Value<String>? result,
    Value<int>? reviewedAt,
  }) {
    return ReviewHistoryCompanion(
      id: id ?? this.id,
      questionId: questionId ?? this.questionId,
      result: result ?? this.result,
      reviewedAt: reviewedAt ?? this.reviewedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (result.present) {
      map['result'] = Variable<String>(result.value);
    }
    if (reviewedAt.present) {
      map['reviewed_at'] = Variable<int>(reviewedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReviewHistoryCompanion(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('result: $result, ')
          ..write('reviewedAt: $reviewedAt')
          ..write(')'))
        .toString();
  }
}

class $CauseRecordsTable extends CauseRecords
    with TableInfo<$CauseRecordsTable, DbCauseRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CauseRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _causeMeta = const VerificationMeta('cause');
  @override
  late final GeneratedColumn<String> cause = GeneratedColumn<String>(
    'cause',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _solvedCountMeta = const VerificationMeta(
    'solvedCount',
  );
  @override
  late final GeneratedColumn<int> solvedCount = GeneratedColumn<int>(
    'solved_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastCheckMeta = const VerificationMeta(
    'lastCheck',
  );
  @override
  late final GeneratedColumn<int> lastCheck = GeneratedColumn<int>(
    'last_check',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _recheckDateMeta = const VerificationMeta(
    'recheckDate',
  );
  @override
  late final GeneratedColumn<int> recheckDate = GeneratedColumn<int>(
    'recheck_date',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String>
  remedyHistory = GeneratedColumn<String>(
    'remedy_history',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  ).withConverter<List<String>>($CauseRecordsTable.$converterremedyHistory);
  static const VerificationMeta _joinedAtMeta = const VerificationMeta(
    'joinedAt',
  );
  @override
  late final GeneratedColumn<int> joinedAt = GeneratedColumn<int>(
    'joined_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    questionId,
    cause,
    subjectId,
    status,
    solvedCount,
    lastCheck,
    recheckDate,
    remedyHistory,
    joinedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cause_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbCauseRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('cause')) {
      context.handle(
        _causeMeta,
        cause.isAcceptableOrUnknown(data['cause']!, _causeMeta),
      );
    } else if (isInserting) {
      context.missing(_causeMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('solved_count')) {
      context.handle(
        _solvedCountMeta,
        solvedCount.isAcceptableOrUnknown(
          data['solved_count']!,
          _solvedCountMeta,
        ),
      );
    }
    if (data.containsKey('last_check')) {
      context.handle(
        _lastCheckMeta,
        lastCheck.isAcceptableOrUnknown(data['last_check']!, _lastCheckMeta),
      );
    }
    if (data.containsKey('recheck_date')) {
      context.handle(
        _recheckDateMeta,
        recheckDate.isAcceptableOrUnknown(
          data['recheck_date']!,
          _recheckDateMeta,
        ),
      );
    }
    if (data.containsKey('joined_at')) {
      context.handle(
        _joinedAtMeta,
        joinedAt.isAcceptableOrUnknown(data['joined_at']!, _joinedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_joinedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbCauseRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbCauseRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      cause: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cause'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      solvedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}solved_count'],
      )!,
      lastCheck: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_check'],
      ),
      recheckDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}recheck_date'],
      ),
      remedyHistory: $CauseRecordsTable.$converterremedyHistory.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}remedy_history'],
        )!,
      ),
      joinedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}joined_at'],
      )!,
    );
  }

  @override
  $CauseRecordsTable createAlias(String alias) {
    return $CauseRecordsTable(attachedDatabase, alias);
  }

  static TypeConverter<List<String>, String> $converterremedyHistory =
      const StringListConverter();
}

class DbCauseRecord extends DataClass implements Insertable<DbCauseRecord> {
  final int id;
  final String questionId;
  final String cause;
  final String subjectId;
  final String status;
  final int solvedCount;
  final int? lastCheck;
  final int? recheckDate;
  final List<String> remedyHistory;
  final int joinedAt;
  const DbCauseRecord({
    required this.id,
    required this.questionId,
    required this.cause,
    required this.subjectId,
    required this.status,
    required this.solvedCount,
    this.lastCheck,
    this.recheckDate,
    required this.remedyHistory,
    required this.joinedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['question_id'] = Variable<String>(questionId);
    map['cause'] = Variable<String>(cause);
    map['subject_id'] = Variable<String>(subjectId);
    map['status'] = Variable<String>(status);
    map['solved_count'] = Variable<int>(solvedCount);
    if (!nullToAbsent || lastCheck != null) {
      map['last_check'] = Variable<int>(lastCheck);
    }
    if (!nullToAbsent || recheckDate != null) {
      map['recheck_date'] = Variable<int>(recheckDate);
    }
    {
      map['remedy_history'] = Variable<String>(
        $CauseRecordsTable.$converterremedyHistory.toSql(remedyHistory),
      );
    }
    map['joined_at'] = Variable<int>(joinedAt);
    return map;
  }

  CauseRecordsCompanion toCompanion(bool nullToAbsent) {
    return CauseRecordsCompanion(
      id: Value(id),
      questionId: Value(questionId),
      cause: Value(cause),
      subjectId: Value(subjectId),
      status: Value(status),
      solvedCount: Value(solvedCount),
      lastCheck: lastCheck == null && nullToAbsent
          ? const Value.absent()
          : Value(lastCheck),
      recheckDate: recheckDate == null && nullToAbsent
          ? const Value.absent()
          : Value(recheckDate),
      remedyHistory: Value(remedyHistory),
      joinedAt: Value(joinedAt),
    );
  }

  factory DbCauseRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbCauseRecord(
      id: serializer.fromJson<int>(json['id']),
      questionId: serializer.fromJson<String>(json['questionId']),
      cause: serializer.fromJson<String>(json['cause']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      status: serializer.fromJson<String>(json['status']),
      solvedCount: serializer.fromJson<int>(json['solvedCount']),
      lastCheck: serializer.fromJson<int?>(json['lastCheck']),
      recheckDate: serializer.fromJson<int?>(json['recheckDate']),
      remedyHistory: serializer.fromJson<List<String>>(json['remedyHistory']),
      joinedAt: serializer.fromJson<int>(json['joinedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'questionId': serializer.toJson<String>(questionId),
      'cause': serializer.toJson<String>(cause),
      'subjectId': serializer.toJson<String>(subjectId),
      'status': serializer.toJson<String>(status),
      'solvedCount': serializer.toJson<int>(solvedCount),
      'lastCheck': serializer.toJson<int?>(lastCheck),
      'recheckDate': serializer.toJson<int?>(recheckDate),
      'remedyHistory': serializer.toJson<List<String>>(remedyHistory),
      'joinedAt': serializer.toJson<int>(joinedAt),
    };
  }

  DbCauseRecord copyWith({
    int? id,
    String? questionId,
    String? cause,
    String? subjectId,
    String? status,
    int? solvedCount,
    Value<int?> lastCheck = const Value.absent(),
    Value<int?> recheckDate = const Value.absent(),
    List<String>? remedyHistory,
    int? joinedAt,
  }) => DbCauseRecord(
    id: id ?? this.id,
    questionId: questionId ?? this.questionId,
    cause: cause ?? this.cause,
    subjectId: subjectId ?? this.subjectId,
    status: status ?? this.status,
    solvedCount: solvedCount ?? this.solvedCount,
    lastCheck: lastCheck.present ? lastCheck.value : this.lastCheck,
    recheckDate: recheckDate.present ? recheckDate.value : this.recheckDate,
    remedyHistory: remedyHistory ?? this.remedyHistory,
    joinedAt: joinedAt ?? this.joinedAt,
  );
  DbCauseRecord copyWithCompanion(CauseRecordsCompanion data) {
    return DbCauseRecord(
      id: data.id.present ? data.id.value : this.id,
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      cause: data.cause.present ? data.cause.value : this.cause,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      status: data.status.present ? data.status.value : this.status,
      solvedCount: data.solvedCount.present
          ? data.solvedCount.value
          : this.solvedCount,
      lastCheck: data.lastCheck.present ? data.lastCheck.value : this.lastCheck,
      recheckDate: data.recheckDate.present
          ? data.recheckDate.value
          : this.recheckDate,
      remedyHistory: data.remedyHistory.present
          ? data.remedyHistory.value
          : this.remedyHistory,
      joinedAt: data.joinedAt.present ? data.joinedAt.value : this.joinedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbCauseRecord(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('cause: $cause, ')
          ..write('subjectId: $subjectId, ')
          ..write('status: $status, ')
          ..write('solvedCount: $solvedCount, ')
          ..write('lastCheck: $lastCheck, ')
          ..write('recheckDate: $recheckDate, ')
          ..write('remedyHistory: $remedyHistory, ')
          ..write('joinedAt: $joinedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    questionId,
    cause,
    subjectId,
    status,
    solvedCount,
    lastCheck,
    recheckDate,
    remedyHistory,
    joinedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbCauseRecord &&
          other.id == this.id &&
          other.questionId == this.questionId &&
          other.cause == this.cause &&
          other.subjectId == this.subjectId &&
          other.status == this.status &&
          other.solvedCount == this.solvedCount &&
          other.lastCheck == this.lastCheck &&
          other.recheckDate == this.recheckDate &&
          other.remedyHistory == this.remedyHistory &&
          other.joinedAt == this.joinedAt);
}

class CauseRecordsCompanion extends UpdateCompanion<DbCauseRecord> {
  final Value<int> id;
  final Value<String> questionId;
  final Value<String> cause;
  final Value<String> subjectId;
  final Value<String> status;
  final Value<int> solvedCount;
  final Value<int?> lastCheck;
  final Value<int?> recheckDate;
  final Value<List<String>> remedyHistory;
  final Value<int> joinedAt;
  const CauseRecordsCompanion({
    this.id = const Value.absent(),
    this.questionId = const Value.absent(),
    this.cause = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.status = const Value.absent(),
    this.solvedCount = const Value.absent(),
    this.lastCheck = const Value.absent(),
    this.recheckDate = const Value.absent(),
    this.remedyHistory = const Value.absent(),
    this.joinedAt = const Value.absent(),
  });
  CauseRecordsCompanion.insert({
    this.id = const Value.absent(),
    required String questionId,
    required String cause,
    required String subjectId,
    this.status = const Value.absent(),
    this.solvedCount = const Value.absent(),
    this.lastCheck = const Value.absent(),
    this.recheckDate = const Value.absent(),
    this.remedyHistory = const Value.absent(),
    required int joinedAt,
  }) : questionId = Value(questionId),
       cause = Value(cause),
       subjectId = Value(subjectId),
       joinedAt = Value(joinedAt);
  static Insertable<DbCauseRecord> custom({
    Expression<int>? id,
    Expression<String>? questionId,
    Expression<String>? cause,
    Expression<String>? subjectId,
    Expression<String>? status,
    Expression<int>? solvedCount,
    Expression<int>? lastCheck,
    Expression<int>? recheckDate,
    Expression<String>? remedyHistory,
    Expression<int>? joinedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (questionId != null) 'question_id': questionId,
      if (cause != null) 'cause': cause,
      if (subjectId != null) 'subject_id': subjectId,
      if (status != null) 'status': status,
      if (solvedCount != null) 'solved_count': solvedCount,
      if (lastCheck != null) 'last_check': lastCheck,
      if (recheckDate != null) 'recheck_date': recheckDate,
      if (remedyHistory != null) 'remedy_history': remedyHistory,
      if (joinedAt != null) 'joined_at': joinedAt,
    });
  }

  CauseRecordsCompanion copyWith({
    Value<int>? id,
    Value<String>? questionId,
    Value<String>? cause,
    Value<String>? subjectId,
    Value<String>? status,
    Value<int>? solvedCount,
    Value<int?>? lastCheck,
    Value<int?>? recheckDate,
    Value<List<String>>? remedyHistory,
    Value<int>? joinedAt,
  }) {
    return CauseRecordsCompanion(
      id: id ?? this.id,
      questionId: questionId ?? this.questionId,
      cause: cause ?? this.cause,
      subjectId: subjectId ?? this.subjectId,
      status: status ?? this.status,
      solvedCount: solvedCount ?? this.solvedCount,
      lastCheck: lastCheck ?? this.lastCheck,
      recheckDate: recheckDate ?? this.recheckDate,
      remedyHistory: remedyHistory ?? this.remedyHistory,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (cause.present) {
      map['cause'] = Variable<String>(cause.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (solvedCount.present) {
      map['solved_count'] = Variable<int>(solvedCount.value);
    }
    if (lastCheck.present) {
      map['last_check'] = Variable<int>(lastCheck.value);
    }
    if (recheckDate.present) {
      map['recheck_date'] = Variable<int>(recheckDate.value);
    }
    if (remedyHistory.present) {
      map['remedy_history'] = Variable<String>(
        $CauseRecordsTable.$converterremedyHistory.toSql(remedyHistory.value),
      );
    }
    if (joinedAt.present) {
      map['joined_at'] = Variable<int>(joinedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CauseRecordsCompanion(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('cause: $cause, ')
          ..write('subjectId: $subjectId, ')
          ..write('status: $status, ')
          ..write('solvedCount: $solvedCount, ')
          ..write('lastCheck: $lastCheck, ')
          ..write('recheckDate: $recheckDate, ')
          ..write('remedyHistory: $remedyHistory, ')
          ..write('joinedAt: $joinedAt')
          ..write(')'))
        .toString();
  }
}

class $ReviewStateTable extends ReviewState
    with TableInfo<$ReviewStateTable, DbReviewState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReviewStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY CHECK (id = 1)',
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<ReviewQueueItem>, String>
  queue = GeneratedColumn<String>(
    'queue',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  ).withConverter<List<ReviewQueueItem>>($ReviewStateTable.$converterqueue);
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, queue, position, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'review_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbReviewState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbReviewState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbReviewState(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      queue: $ReviewStateTable.$converterqueue.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}queue'],
        )!,
      ),
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ReviewStateTable createAlias(String alias) {
    return $ReviewStateTable(attachedDatabase, alias);
  }

  static TypeConverter<List<ReviewQueueItem>, String> $converterqueue =
      const QueueConverter();
}

class DbReviewState extends DataClass implements Insertable<DbReviewState> {
  final int id;
  final List<ReviewQueueItem> queue;
  final int position;
  final int updatedAt;
  const DbReviewState({
    required this.id,
    required this.queue,
    required this.position,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    {
      map['queue'] = Variable<String>(
        $ReviewStateTable.$converterqueue.toSql(queue),
      );
    }
    map['position'] = Variable<int>(position);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ReviewStateCompanion toCompanion(bool nullToAbsent) {
    return ReviewStateCompanion(
      id: Value(id),
      queue: Value(queue),
      position: Value(position),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbReviewState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbReviewState(
      id: serializer.fromJson<int>(json['id']),
      queue: serializer.fromJson<List<ReviewQueueItem>>(json['queue']),
      position: serializer.fromJson<int>(json['position']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'queue': serializer.toJson<List<ReviewQueueItem>>(queue),
      'position': serializer.toJson<int>(position),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DbReviewState copyWith({
    int? id,
    List<ReviewQueueItem>? queue,
    int? position,
    int? updatedAt,
  }) => DbReviewState(
    id: id ?? this.id,
    queue: queue ?? this.queue,
    position: position ?? this.position,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbReviewState copyWithCompanion(ReviewStateCompanion data) {
    return DbReviewState(
      id: data.id.present ? data.id.value : this.id,
      queue: data.queue.present ? data.queue.value : this.queue,
      position: data.position.present ? data.position.value : this.position,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbReviewState(')
          ..write('id: $id, ')
          ..write('queue: $queue, ')
          ..write('position: $position, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, queue, position, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbReviewState &&
          other.id == this.id &&
          other.queue == this.queue &&
          other.position == this.position &&
          other.updatedAt == this.updatedAt);
}

class ReviewStateCompanion extends UpdateCompanion<DbReviewState> {
  final Value<int> id;
  final Value<List<ReviewQueueItem>> queue;
  final Value<int> position;
  final Value<int> updatedAt;
  const ReviewStateCompanion({
    this.id = const Value.absent(),
    this.queue = const Value.absent(),
    this.position = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ReviewStateCompanion.insert({
    this.id = const Value.absent(),
    this.queue = const Value.absent(),
    this.position = const Value.absent(),
    required int updatedAt,
  }) : updatedAt = Value(updatedAt);
  static Insertable<DbReviewState> custom({
    Expression<int>? id,
    Expression<String>? queue,
    Expression<int>? position,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (queue != null) 'queue': queue,
      if (position != null) 'position': position,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ReviewStateCompanion copyWith({
    Value<int>? id,
    Value<List<ReviewQueueItem>>? queue,
    Value<int>? position,
    Value<int>? updatedAt,
  }) {
    return ReviewStateCompanion(
      id: id ?? this.id,
      queue: queue ?? this.queue,
      position: position ?? this.position,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (queue.present) {
      map['queue'] = Variable<String>(
        $ReviewStateTable.$converterqueue.toSql(queue.value),
      );
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReviewStateCompanion(')
          ..write('id: $id, ')
          ..write('queue: $queue, ')
          ..write('position: $position, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $CollectTasksTable extends CollectTasks
    with TableInfo<$CollectTasksTable, DbCollectTask> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CollectTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('queued'),
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<int> progress = GeneratedColumn<int>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _pageCountMeta = const VerificationMeta(
    'pageCount',
  );
  @override
  late final GeneratedColumn<int> pageCount = GeneratedColumn<int>(
    'page_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sourcePathMeta = const VerificationMeta(
    'sourcePath',
  );
  @override
  late final GeneratedColumn<String> sourcePath = GeneratedColumn<String>(
    'source_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  late final GeneratedColumnWithTypeConverter<Map<int, int>, String>
  pageRotations = GeneratedColumn<String>(
    'page_rotations',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  ).withConverter<Map<int, int>>($CollectTasksTable.$converterpageRotations);
  static const VerificationMeta _sourceHashMeta = const VerificationMeta(
    'sourceHash',
  );
  @override
  late final GeneratedColumn<String> sourceHash = GeneratedColumn<String>(
    'source_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    fileName,
    subjectId,
    status,
    progress,
    pageCount,
    page,
    error,
    questionId,
    createdAt,
    sourcePath,
    pageRotations,
    sourceHash,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'collect_tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbCollectTask> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('page_count')) {
      context.handle(
        _pageCountMeta,
        pageCount.isAcceptableOrUnknown(data['page_count']!, _pageCountMeta),
      );
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('source_path')) {
      context.handle(
        _sourcePathMeta,
        sourcePath.isAcceptableOrUnknown(data['source_path']!, _sourcePathMeta),
      );
    }
    if (data.containsKey('source_hash')) {
      context.handle(
        _sourceHashMeta,
        sourceHash.isAcceptableOrUnknown(data['source_hash']!, _sourceHashMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbCollectTask map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbCollectTask(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}progress'],
      )!,
      pageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_count'],
      )!,
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      sourcePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_path'],
      )!,
      pageRotations: $CollectTasksTable.$converterpageRotations.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}page_rotations'],
        )!,
      ),
      sourceHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_hash'],
      ),
    );
  }

  @override
  $CollectTasksTable createAlias(String alias) {
    return $CollectTasksTable(attachedDatabase, alias);
  }

  static TypeConverter<Map<int, int>, String> $converterpageRotations =
      const RotationsConverter();
}

class DbCollectTask extends DataClass implements Insertable<DbCollectTask> {
  final String id;
  final String name;
  final String fileName;
  final String subjectId;
  final String status;
  final int progress;
  final int pageCount;
  final int page;
  final String? error;
  final String? questionId;
  final int createdAt;
  final String sourcePath;
  final Map<int, int> pageRotations;

  /// 十二批 D-91：导入时存进来的原文件 SHA-256（contentHashOfFile）。
  /// 重试时重算库内原图的哈希比对，内容被换过即拒绝重试。旧行（v2
  /// 备份恢复、v2 库迁移而来）为 NULL——无基线可比，重试时跳过指纹
  /// 校验（仍受单候选 + 任务目录口径约束）。
  final String? sourceHash;
  const DbCollectTask({
    required this.id,
    required this.name,
    required this.fileName,
    required this.subjectId,
    required this.status,
    required this.progress,
    required this.pageCount,
    required this.page,
    this.error,
    this.questionId,
    required this.createdAt,
    required this.sourcePath,
    required this.pageRotations,
    this.sourceHash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['file_name'] = Variable<String>(fileName);
    map['subject_id'] = Variable<String>(subjectId);
    map['status'] = Variable<String>(status);
    map['progress'] = Variable<int>(progress);
    map['page_count'] = Variable<int>(pageCount);
    map['page'] = Variable<int>(page);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    if (!nullToAbsent || questionId != null) {
      map['question_id'] = Variable<String>(questionId);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['source_path'] = Variable<String>(sourcePath);
    {
      map['page_rotations'] = Variable<String>(
        $CollectTasksTable.$converterpageRotations.toSql(pageRotations),
      );
    }
    if (!nullToAbsent || sourceHash != null) {
      map['source_hash'] = Variable<String>(sourceHash);
    }
    return map;
  }

  CollectTasksCompanion toCompanion(bool nullToAbsent) {
    return CollectTasksCompanion(
      id: Value(id),
      name: Value(name),
      fileName: Value(fileName),
      subjectId: Value(subjectId),
      status: Value(status),
      progress: Value(progress),
      pageCount: Value(pageCount),
      page: Value(page),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      questionId: questionId == null && nullToAbsent
          ? const Value.absent()
          : Value(questionId),
      createdAt: Value(createdAt),
      sourcePath: Value(sourcePath),
      pageRotations: Value(pageRotations),
      sourceHash: sourceHash == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceHash),
    );
  }

  factory DbCollectTask.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbCollectTask(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      fileName: serializer.fromJson<String>(json['fileName']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      status: serializer.fromJson<String>(json['status']),
      progress: serializer.fromJson<int>(json['progress']),
      pageCount: serializer.fromJson<int>(json['pageCount']),
      page: serializer.fromJson<int>(json['page']),
      error: serializer.fromJson<String?>(json['error']),
      questionId: serializer.fromJson<String?>(json['questionId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      sourcePath: serializer.fromJson<String>(json['sourcePath']),
      pageRotations: serializer.fromJson<Map<int, int>>(json['pageRotations']),
      sourceHash: serializer.fromJson<String?>(json['sourceHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'fileName': serializer.toJson<String>(fileName),
      'subjectId': serializer.toJson<String>(subjectId),
      'status': serializer.toJson<String>(status),
      'progress': serializer.toJson<int>(progress),
      'pageCount': serializer.toJson<int>(pageCount),
      'page': serializer.toJson<int>(page),
      'error': serializer.toJson<String?>(error),
      'questionId': serializer.toJson<String?>(questionId),
      'createdAt': serializer.toJson<int>(createdAt),
      'sourcePath': serializer.toJson<String>(sourcePath),
      'pageRotations': serializer.toJson<Map<int, int>>(pageRotations),
      'sourceHash': serializer.toJson<String?>(sourceHash),
    };
  }

  DbCollectTask copyWith({
    String? id,
    String? name,
    String? fileName,
    String? subjectId,
    String? status,
    int? progress,
    int? pageCount,
    int? page,
    Value<String?> error = const Value.absent(),
    Value<String?> questionId = const Value.absent(),
    int? createdAt,
    String? sourcePath,
    Map<int, int>? pageRotations,
    Value<String?> sourceHash = const Value.absent(),
  }) => DbCollectTask(
    id: id ?? this.id,
    name: name ?? this.name,
    fileName: fileName ?? this.fileName,
    subjectId: subjectId ?? this.subjectId,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    pageCount: pageCount ?? this.pageCount,
    page: page ?? this.page,
    error: error.present ? error.value : this.error,
    questionId: questionId.present ? questionId.value : this.questionId,
    createdAt: createdAt ?? this.createdAt,
    sourcePath: sourcePath ?? this.sourcePath,
    pageRotations: pageRotations ?? this.pageRotations,
    sourceHash: sourceHash.present ? sourceHash.value : this.sourceHash,
  );
  DbCollectTask copyWithCompanion(CollectTasksCompanion data) {
    return DbCollectTask(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      status: data.status.present ? data.status.value : this.status,
      progress: data.progress.present ? data.progress.value : this.progress,
      pageCount: data.pageCount.present ? data.pageCount.value : this.pageCount,
      page: data.page.present ? data.page.value : this.page,
      error: data.error.present ? data.error.value : this.error,
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      sourcePath: data.sourcePath.present
          ? data.sourcePath.value
          : this.sourcePath,
      pageRotations: data.pageRotations.present
          ? data.pageRotations.value
          : this.pageRotations,
      sourceHash: data.sourceHash.present
          ? data.sourceHash.value
          : this.sourceHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbCollectTask(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('fileName: $fileName, ')
          ..write('subjectId: $subjectId, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('pageCount: $pageCount, ')
          ..write('page: $page, ')
          ..write('error: $error, ')
          ..write('questionId: $questionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('sourcePath: $sourcePath, ')
          ..write('pageRotations: $pageRotations, ')
          ..write('sourceHash: $sourceHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    fileName,
    subjectId,
    status,
    progress,
    pageCount,
    page,
    error,
    questionId,
    createdAt,
    sourcePath,
    pageRotations,
    sourceHash,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbCollectTask &&
          other.id == this.id &&
          other.name == this.name &&
          other.fileName == this.fileName &&
          other.subjectId == this.subjectId &&
          other.status == this.status &&
          other.progress == this.progress &&
          other.pageCount == this.pageCount &&
          other.page == this.page &&
          other.error == this.error &&
          other.questionId == this.questionId &&
          other.createdAt == this.createdAt &&
          other.sourcePath == this.sourcePath &&
          other.pageRotations == this.pageRotations &&
          other.sourceHash == this.sourceHash);
}

class CollectTasksCompanion extends UpdateCompanion<DbCollectTask> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> fileName;
  final Value<String> subjectId;
  final Value<String> status;
  final Value<int> progress;
  final Value<int> pageCount;
  final Value<int> page;
  final Value<String?> error;
  final Value<String?> questionId;
  final Value<int> createdAt;
  final Value<String> sourcePath;
  final Value<Map<int, int>> pageRotations;
  final Value<String?> sourceHash;
  final Value<int> rowid;
  const CollectTasksCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.fileName = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.status = const Value.absent(),
    this.progress = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.page = const Value.absent(),
    this.error = const Value.absent(),
    this.questionId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.sourcePath = const Value.absent(),
    this.pageRotations = const Value.absent(),
    this.sourceHash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CollectTasksCompanion.insert({
    required String id,
    required String name,
    required String fileName,
    required String subjectId,
    this.status = const Value.absent(),
    this.progress = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.page = const Value.absent(),
    this.error = const Value.absent(),
    this.questionId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.sourcePath = const Value.absent(),
    this.pageRotations = const Value.absent(),
    this.sourceHash = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       fileName = Value(fileName),
       subjectId = Value(subjectId);
  static Insertable<DbCollectTask> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? fileName,
    Expression<String>? subjectId,
    Expression<String>? status,
    Expression<int>? progress,
    Expression<int>? pageCount,
    Expression<int>? page,
    Expression<String>? error,
    Expression<String>? questionId,
    Expression<int>? createdAt,
    Expression<String>? sourcePath,
    Expression<String>? pageRotations,
    Expression<String>? sourceHash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (fileName != null) 'file_name': fileName,
      if (subjectId != null) 'subject_id': subjectId,
      if (status != null) 'status': status,
      if (progress != null) 'progress': progress,
      if (pageCount != null) 'page_count': pageCount,
      if (page != null) 'page': page,
      if (error != null) 'error': error,
      if (questionId != null) 'question_id': questionId,
      if (createdAt != null) 'created_at': createdAt,
      if (sourcePath != null) 'source_path': sourcePath,
      if (pageRotations != null) 'page_rotations': pageRotations,
      if (sourceHash != null) 'source_hash': sourceHash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CollectTasksCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? fileName,
    Value<String>? subjectId,
    Value<String>? status,
    Value<int>? progress,
    Value<int>? pageCount,
    Value<int>? page,
    Value<String?>? error,
    Value<String?>? questionId,
    Value<int>? createdAt,
    Value<String>? sourcePath,
    Value<Map<int, int>>? pageRotations,
    Value<String?>? sourceHash,
    Value<int>? rowid,
  }) {
    return CollectTasksCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      fileName: fileName ?? this.fileName,
      subjectId: subjectId ?? this.subjectId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      pageCount: pageCount ?? this.pageCount,
      page: page ?? this.page,
      error: error ?? this.error,
      questionId: questionId ?? this.questionId,
      createdAt: createdAt ?? this.createdAt,
      sourcePath: sourcePath ?? this.sourcePath,
      pageRotations: pageRotations ?? this.pageRotations,
      sourceHash: sourceHash ?? this.sourceHash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (progress.present) {
      map['progress'] = Variable<int>(progress.value);
    }
    if (pageCount.present) {
      map['page_count'] = Variable<int>(pageCount.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (sourcePath.present) {
      map['source_path'] = Variable<String>(sourcePath.value);
    }
    if (pageRotations.present) {
      map['page_rotations'] = Variable<String>(
        $CollectTasksTable.$converterpageRotations.toSql(pageRotations.value),
      );
    }
    if (sourceHash.present) {
      map['source_hash'] = Variable<String>(sourceHash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CollectTasksCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('fileName: $fileName, ')
          ..write('subjectId: $subjectId, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('pageCount: $pageCount, ')
          ..write('page: $page, ')
          ..write('error: $error, ')
          ..write('questionId: $questionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('sourcePath: $sourcePath, ')
          ..write('pageRotations: $pageRotations, ')
          ..write('sourceHash: $sourceHash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $QuestionBoxesTable extends QuestionBoxes
    with TableInfo<$QuestionBoxesTable, DbQuestionBox> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuestionBoxesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _collectTaskIdMeta = const VerificationMeta(
    'collectTaskId',
  );
  @override
  late final GeneratedColumn<String> collectTaskId = GeneratedColumn<String>(
    'collect_task_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentBoxIdMeta = const VerificationMeta(
    'parentBoxId',
  );
  @override
  late final GeneratedColumn<String> parentBoxId = GeneratedColumn<String>(
    'parent_box_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 1 CHECK (page >= 1)',
    defaultValue: const CustomExpression('1'),
  );
  static const VerificationMeta _layerMeta = const VerificationMeta('layer');
  @override
  late final GeneratedColumn<int> layer = GeneratedColumn<int>(
    'layer',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (layer IN (1, 2))',
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (type IN (\'question\', \'stem\', \'option\', \'figure\'))',
  );
  static const VerificationMeta _xMeta = const VerificationMeta('x');
  @override
  late final GeneratedColumn<double> x = GeneratedColumn<double>(
    'x',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (x >= 0 AND x <= 1)',
  );
  static const VerificationMeta _yMeta = const VerificationMeta('y');
  @override
  late final GeneratedColumn<double> y = GeneratedColumn<double>(
    'y',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (y >= 0 AND y <= 1)',
  );
  static const VerificationMeta _wMeta = const VerificationMeta('w');
  @override
  late final GeneratedColumn<double> w = GeneratedColumn<double>(
    'w',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (w >= 0 AND w <= 1)',
  );
  static const VerificationMeta _hMeta = const VerificationMeta('h');
  @override
  late final GeneratedColumn<double> h = GeneratedColumn<double>(
    'h',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (h >= 0 AND h <= 1)',
  );
  static const VerificationMeta _confidenceMeta = const VerificationMeta(
    'confidence',
  );
  @override
  late final GeneratedColumn<double> confidence = GeneratedColumn<double>(
    'confidence',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    $customConstraints:
        'CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))',
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints:
        'NOT NULL DEFAULT \'manual\' CHECK (origin IN (\'yolo\', \'manual\'))',
    defaultValue: const CustomExpression('\'manual\''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    collectTaskId,
    questionId,
    parentBoxId,
    page,
    layer,
    type,
    x,
    y,
    w,
    h,
    confidence,
    origin,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'question_boxes';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbQuestionBox> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('collect_task_id')) {
      context.handle(
        _collectTaskIdMeta,
        collectTaskId.isAcceptableOrUnknown(
          data['collect_task_id']!,
          _collectTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    }
    if (data.containsKey('parent_box_id')) {
      context.handle(
        _parentBoxIdMeta,
        parentBoxId.isAcceptableOrUnknown(
          data['parent_box_id']!,
          _parentBoxIdMeta,
        ),
      );
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    }
    if (data.containsKey('layer')) {
      context.handle(
        _layerMeta,
        layer.isAcceptableOrUnknown(data['layer']!, _layerMeta),
      );
    } else if (isInserting) {
      context.missing(_layerMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('x')) {
      context.handle(_xMeta, x.isAcceptableOrUnknown(data['x']!, _xMeta));
    } else if (isInserting) {
      context.missing(_xMeta);
    }
    if (data.containsKey('y')) {
      context.handle(_yMeta, y.isAcceptableOrUnknown(data['y']!, _yMeta));
    } else if (isInserting) {
      context.missing(_yMeta);
    }
    if (data.containsKey('w')) {
      context.handle(_wMeta, w.isAcceptableOrUnknown(data['w']!, _wMeta));
    } else if (isInserting) {
      context.missing(_wMeta);
    }
    if (data.containsKey('h')) {
      context.handle(_hMeta, h.isAcceptableOrUnknown(data['h']!, _hMeta));
    } else if (isInserting) {
      context.missing(_hMeta);
    }
    if (data.containsKey('confidence')) {
      context.handle(
        _confidenceMeta,
        confidence.isAcceptableOrUnknown(data['confidence']!, _confidenceMeta),
      );
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbQuestionBox map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbQuestionBox(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      collectTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}collect_task_id'],
      ),
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      ),
      parentBoxId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_box_id'],
      ),
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      layer: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}layer'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      x: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}x'],
      )!,
      y: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}y'],
      )!,
      w: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}w'],
      )!,
      h: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}h'],
      )!,
      confidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}confidence'],
      ),
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $QuestionBoxesTable createAlias(String alias) {
    return $QuestionBoxesTable(attachedDatabase, alias);
  }
}

class DbQuestionBox extends DataClass implements Insertable<DbQuestionBox> {
  final String id;
  final String? collectTaskId;
  final String? questionId;
  final String? parentBoxId;
  final int page;
  final int layer;
  final String type;
  final double x;
  final double y;
  final double w;
  final double h;
  final double? confidence;
  final String origin;
  final int updatedAt;
  const DbQuestionBox({
    required this.id,
    this.collectTaskId,
    this.questionId,
    this.parentBoxId,
    required this.page,
    required this.layer,
    required this.type,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.confidence,
    required this.origin,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || collectTaskId != null) {
      map['collect_task_id'] = Variable<String>(collectTaskId);
    }
    if (!nullToAbsent || questionId != null) {
      map['question_id'] = Variable<String>(questionId);
    }
    if (!nullToAbsent || parentBoxId != null) {
      map['parent_box_id'] = Variable<String>(parentBoxId);
    }
    map['page'] = Variable<int>(page);
    map['layer'] = Variable<int>(layer);
    map['type'] = Variable<String>(type);
    map['x'] = Variable<double>(x);
    map['y'] = Variable<double>(y);
    map['w'] = Variable<double>(w);
    map['h'] = Variable<double>(h);
    if (!nullToAbsent || confidence != null) {
      map['confidence'] = Variable<double>(confidence);
    }
    map['origin'] = Variable<String>(origin);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  QuestionBoxesCompanion toCompanion(bool nullToAbsent) {
    return QuestionBoxesCompanion(
      id: Value(id),
      collectTaskId: collectTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(collectTaskId),
      questionId: questionId == null && nullToAbsent
          ? const Value.absent()
          : Value(questionId),
      parentBoxId: parentBoxId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentBoxId),
      page: Value(page),
      layer: Value(layer),
      type: Value(type),
      x: Value(x),
      y: Value(y),
      w: Value(w),
      h: Value(h),
      confidence: confidence == null && nullToAbsent
          ? const Value.absent()
          : Value(confidence),
      origin: Value(origin),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbQuestionBox.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbQuestionBox(
      id: serializer.fromJson<String>(json['id']),
      collectTaskId: serializer.fromJson<String?>(json['collectTaskId']),
      questionId: serializer.fromJson<String?>(json['questionId']),
      parentBoxId: serializer.fromJson<String?>(json['parentBoxId']),
      page: serializer.fromJson<int>(json['page']),
      layer: serializer.fromJson<int>(json['layer']),
      type: serializer.fromJson<String>(json['type']),
      x: serializer.fromJson<double>(json['x']),
      y: serializer.fromJson<double>(json['y']),
      w: serializer.fromJson<double>(json['w']),
      h: serializer.fromJson<double>(json['h']),
      confidence: serializer.fromJson<double?>(json['confidence']),
      origin: serializer.fromJson<String>(json['origin']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'collectTaskId': serializer.toJson<String?>(collectTaskId),
      'questionId': serializer.toJson<String?>(questionId),
      'parentBoxId': serializer.toJson<String?>(parentBoxId),
      'page': serializer.toJson<int>(page),
      'layer': serializer.toJson<int>(layer),
      'type': serializer.toJson<String>(type),
      'x': serializer.toJson<double>(x),
      'y': serializer.toJson<double>(y),
      'w': serializer.toJson<double>(w),
      'h': serializer.toJson<double>(h),
      'confidence': serializer.toJson<double?>(confidence),
      'origin': serializer.toJson<String>(origin),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DbQuestionBox copyWith({
    String? id,
    Value<String?> collectTaskId = const Value.absent(),
    Value<String?> questionId = const Value.absent(),
    Value<String?> parentBoxId = const Value.absent(),
    int? page,
    int? layer,
    String? type,
    double? x,
    double? y,
    double? w,
    double? h,
    Value<double?> confidence = const Value.absent(),
    String? origin,
    int? updatedAt,
  }) => DbQuestionBox(
    id: id ?? this.id,
    collectTaskId: collectTaskId.present
        ? collectTaskId.value
        : this.collectTaskId,
    questionId: questionId.present ? questionId.value : this.questionId,
    parentBoxId: parentBoxId.present ? parentBoxId.value : this.parentBoxId,
    page: page ?? this.page,
    layer: layer ?? this.layer,
    type: type ?? this.type,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    confidence: confidence.present ? confidence.value : this.confidence,
    origin: origin ?? this.origin,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbQuestionBox copyWithCompanion(QuestionBoxesCompanion data) {
    return DbQuestionBox(
      id: data.id.present ? data.id.value : this.id,
      collectTaskId: data.collectTaskId.present
          ? data.collectTaskId.value
          : this.collectTaskId,
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      parentBoxId: data.parentBoxId.present
          ? data.parentBoxId.value
          : this.parentBoxId,
      page: data.page.present ? data.page.value : this.page,
      layer: data.layer.present ? data.layer.value : this.layer,
      type: data.type.present ? data.type.value : this.type,
      x: data.x.present ? data.x.value : this.x,
      y: data.y.present ? data.y.value : this.y,
      w: data.w.present ? data.w.value : this.w,
      h: data.h.present ? data.h.value : this.h,
      confidence: data.confidence.present
          ? data.confidence.value
          : this.confidence,
      origin: data.origin.present ? data.origin.value : this.origin,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbQuestionBox(')
          ..write('id: $id, ')
          ..write('collectTaskId: $collectTaskId, ')
          ..write('questionId: $questionId, ')
          ..write('parentBoxId: $parentBoxId, ')
          ..write('page: $page, ')
          ..write('layer: $layer, ')
          ..write('type: $type, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('confidence: $confidence, ')
          ..write('origin: $origin, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    collectTaskId,
    questionId,
    parentBoxId,
    page,
    layer,
    type,
    x,
    y,
    w,
    h,
    confidence,
    origin,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbQuestionBox &&
          other.id == this.id &&
          other.collectTaskId == this.collectTaskId &&
          other.questionId == this.questionId &&
          other.parentBoxId == this.parentBoxId &&
          other.page == this.page &&
          other.layer == this.layer &&
          other.type == this.type &&
          other.x == this.x &&
          other.y == this.y &&
          other.w == this.w &&
          other.h == this.h &&
          other.confidence == this.confidence &&
          other.origin == this.origin &&
          other.updatedAt == this.updatedAt);
}

class QuestionBoxesCompanion extends UpdateCompanion<DbQuestionBox> {
  final Value<String> id;
  final Value<String?> collectTaskId;
  final Value<String?> questionId;
  final Value<String?> parentBoxId;
  final Value<int> page;
  final Value<int> layer;
  final Value<String> type;
  final Value<double> x;
  final Value<double> y;
  final Value<double> w;
  final Value<double> h;
  final Value<double?> confidence;
  final Value<String> origin;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const QuestionBoxesCompanion({
    this.id = const Value.absent(),
    this.collectTaskId = const Value.absent(),
    this.questionId = const Value.absent(),
    this.parentBoxId = const Value.absent(),
    this.page = const Value.absent(),
    this.layer = const Value.absent(),
    this.type = const Value.absent(),
    this.x = const Value.absent(),
    this.y = const Value.absent(),
    this.w = const Value.absent(),
    this.h = const Value.absent(),
    this.confidence = const Value.absent(),
    this.origin = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QuestionBoxesCompanion.insert({
    required String id,
    this.collectTaskId = const Value.absent(),
    this.questionId = const Value.absent(),
    this.parentBoxId = const Value.absent(),
    this.page = const Value.absent(),
    required int layer,
    required String type,
    required double x,
    required double y,
    required double w,
    required double h,
    this.confidence = const Value.absent(),
    this.origin = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       layer = Value(layer),
       type = Value(type),
       x = Value(x),
       y = Value(y),
       w = Value(w),
       h = Value(h),
       updatedAt = Value(updatedAt);
  static Insertable<DbQuestionBox> custom({
    Expression<String>? id,
    Expression<String>? collectTaskId,
    Expression<String>? questionId,
    Expression<String>? parentBoxId,
    Expression<int>? page,
    Expression<int>? layer,
    Expression<String>? type,
    Expression<double>? x,
    Expression<double>? y,
    Expression<double>? w,
    Expression<double>? h,
    Expression<double>? confidence,
    Expression<String>? origin,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (collectTaskId != null) 'collect_task_id': collectTaskId,
      if (questionId != null) 'question_id': questionId,
      if (parentBoxId != null) 'parent_box_id': parentBoxId,
      if (page != null) 'page': page,
      if (layer != null) 'layer': layer,
      if (type != null) 'type': type,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (w != null) 'w': w,
      if (h != null) 'h': h,
      if (confidence != null) 'confidence': confidence,
      if (origin != null) 'origin': origin,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QuestionBoxesCompanion copyWith({
    Value<String>? id,
    Value<String?>? collectTaskId,
    Value<String?>? questionId,
    Value<String?>? parentBoxId,
    Value<int>? page,
    Value<int>? layer,
    Value<String>? type,
    Value<double>? x,
    Value<double>? y,
    Value<double>? w,
    Value<double>? h,
    Value<double?>? confidence,
    Value<String>? origin,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return QuestionBoxesCompanion(
      id: id ?? this.id,
      collectTaskId: collectTaskId ?? this.collectTaskId,
      questionId: questionId ?? this.questionId,
      parentBoxId: parentBoxId ?? this.parentBoxId,
      page: page ?? this.page,
      layer: layer ?? this.layer,
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      confidence: confidence ?? this.confidence,
      origin: origin ?? this.origin,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (collectTaskId.present) {
      map['collect_task_id'] = Variable<String>(collectTaskId.value);
    }
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (parentBoxId.present) {
      map['parent_box_id'] = Variable<String>(parentBoxId.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (layer.present) {
      map['layer'] = Variable<int>(layer.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (x.present) {
      map['x'] = Variable<double>(x.value);
    }
    if (y.present) {
      map['y'] = Variable<double>(y.value);
    }
    if (w.present) {
      map['w'] = Variable<double>(w.value);
    }
    if (h.present) {
      map['h'] = Variable<double>(h.value);
    }
    if (confidence.present) {
      map['confidence'] = Variable<double>(confidence.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuestionBoxesCompanion(')
          ..write('id: $id, ')
          ..write('collectTaskId: $collectTaskId, ')
          ..write('questionId: $questionId, ')
          ..write('parentBoxId: $parentBoxId, ')
          ..write('page: $page, ')
          ..write('layer: $layer, ')
          ..write('type: $type, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('confidence: $confidence, ')
          ..write('origin: $origin, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $QuestionsTable extends Questions
    with TableInfo<$QuestionsTable, DbQuestion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuestionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String> folderIds =
      GeneratedColumn<String>(
        'folder_ids',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      ).withConverter<List<String>>($QuestionsTable.$converterfolderIds);
  static const VerificationMeta _examIdMeta = const VerificationMeta('examId');
  @override
  late final GeneratedColumn<String> examId = GeneratedColumn<String>(
    'exam_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String>
  knowledgeIds = GeneratedColumn<String>(
    'knowledge_ids',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  ).withConverter<List<String>>($QuestionsTable.$converterknowledgeIds);
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String> errorTypes =
      GeneratedColumn<String>(
        'error_types',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      ).withConverter<List<String>>($QuestionsTable.$convertererrorTypes);
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String>
  customErrorTypes = GeneratedColumn<String>(
    'custom_error_types',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  ).withConverter<List<String>>($QuestionsTable.$convertercustomErrorTypes);
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String> tags =
      GeneratedColumn<String>(
        'tags',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      ).withConverter<List<String>>($QuestionsTable.$convertertags);
  static const VerificationMeta _answerMeta = const VerificationMeta('answer');
  @override
  late final GeneratedColumn<String> answer = GeneratedColumn<String>(
    'answer',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _explanationMeta = const VerificationMeta(
    'explanation',
  );
  @override
  late final GeneratedColumn<String> explanation = GeneratedColumn<String>(
    'explanation',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reviewCountMeta = const VerificationMeta(
    'reviewCount',
  );
  @override
  late final GeneratedColumn<int> reviewCount = GeneratedColumn<int>(
    'review_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isOrganizedMeta = const VerificationMeta(
    'isOrganized',
  );
  @override
  late final GeneratedColumn<int> isOrganized = GeneratedColumn<int>(
    'is_organized',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isDemoMeta = const VerificationMeta('isDemo');
  @override
  late final GeneratedColumn<int> isDemo = GeneratedColumn<int>(
    'is_demo',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isFavoriteMeta = const VerificationMeta(
    'isFavorite',
  );
  @override
  late final GeneratedColumn<int> isFavorite = GeneratedColumn<int>(
    'is_favorite',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isArchivedMeta = const VerificationMeta(
    'isArchived',
  );
  @override
  late final GeneratedColumn<int> isArchived = GeneratedColumn<int>(
    'is_archived',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _reviewJoinedMeta = const VerificationMeta(
    'reviewJoined',
  );
  @override
  late final GeneratedColumn<int> reviewJoined = GeneratedColumn<int>(
    'review_joined',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sliceKindMeta = const VerificationMeta(
    'sliceKind',
  );
  @override
  late final GeneratedColumn<String> sliceKind = GeneratedColumn<String>(
    'slice_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('material'),
  );
  static const VerificationMeta _sliceTextMeta = const VerificationMeta(
    'sliceText',
  );
  @override
  late final GeneratedColumn<String> sliceText = GeneratedColumn<String>(
    'slice_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sourcePathMeta = const VerificationMeta(
    'sourcePath',
  );
  @override
  late final GeneratedColumn<String> sourcePath = GeneratedColumn<String>(
    'source_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceKindMeta = const VerificationMeta(
    'sourceKind',
  );
  @override
  late final GeneratedColumn<String> sourceKind = GeneratedColumn<String>(
    'source_kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourcePageMeta = const VerificationMeta(
    'sourcePage',
  );
  @override
  late final GeneratedColumn<int> sourcePage = GeneratedColumn<int>(
    'source_page',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageImagePathMeta = const VerificationMeta(
    'pageImagePath',
  );
  @override
  late final GeneratedColumn<String> pageImagePath = GeneratedColumn<String>(
    'page_image_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _slicePathMeta = const VerificationMeta(
    'slicePath',
  );
  @override
  late final GeneratedColumn<String> slicePath = GeneratedColumn<String>(
    'slice_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sliceWidthMeta = const VerificationMeta(
    'sliceWidth',
  );
  @override
  late final GeneratedColumn<int> sliceWidth = GeneratedColumn<int>(
    'slice_width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sliceHeightMeta = const VerificationMeta(
    'sliceHeight',
  );
  @override
  late final GeneratedColumn<int> sliceHeight = GeneratedColumn<int>(
    'slice_height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    subjectId,
    folderIds,
    examId,
    knowledgeIds,
    errorTypes,
    customErrorTypes,
    tags,
    answer,
    explanation,
    notes,
    reviewCount,
    isOrganized,
    isDemo,
    isFavorite,
    isArchived,
    reviewJoined,
    createdAt,
    sliceKind,
    sliceText,
    sourcePath,
    sourceKind,
    sourcePage,
    pageImagePath,
    slicePath,
    sliceWidth,
    sliceHeight,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'questions';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbQuestion> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('exam_id')) {
      context.handle(
        _examIdMeta,
        examId.isAcceptableOrUnknown(data['exam_id']!, _examIdMeta),
      );
    }
    if (data.containsKey('answer')) {
      context.handle(
        _answerMeta,
        answer.isAcceptableOrUnknown(data['answer']!, _answerMeta),
      );
    }
    if (data.containsKey('explanation')) {
      context.handle(
        _explanationMeta,
        explanation.isAcceptableOrUnknown(
          data['explanation']!,
          _explanationMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('review_count')) {
      context.handle(
        _reviewCountMeta,
        reviewCount.isAcceptableOrUnknown(
          data['review_count']!,
          _reviewCountMeta,
        ),
      );
    }
    if (data.containsKey('is_organized')) {
      context.handle(
        _isOrganizedMeta,
        isOrganized.isAcceptableOrUnknown(
          data['is_organized']!,
          _isOrganizedMeta,
        ),
      );
    }
    if (data.containsKey('is_demo')) {
      context.handle(
        _isDemoMeta,
        isDemo.isAcceptableOrUnknown(data['is_demo']!, _isDemoMeta),
      );
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
        _isFavoriteMeta,
        isFavorite.isAcceptableOrUnknown(data['is_favorite']!, _isFavoriteMeta),
      );
    }
    if (data.containsKey('is_archived')) {
      context.handle(
        _isArchivedMeta,
        isArchived.isAcceptableOrUnknown(data['is_archived']!, _isArchivedMeta),
      );
    }
    if (data.containsKey('review_joined')) {
      context.handle(
        _reviewJoinedMeta,
        reviewJoined.isAcceptableOrUnknown(
          data['review_joined']!,
          _reviewJoinedMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('slice_kind')) {
      context.handle(
        _sliceKindMeta,
        sliceKind.isAcceptableOrUnknown(data['slice_kind']!, _sliceKindMeta),
      );
    }
    if (data.containsKey('slice_text')) {
      context.handle(
        _sliceTextMeta,
        sliceText.isAcceptableOrUnknown(data['slice_text']!, _sliceTextMeta),
      );
    }
    if (data.containsKey('source_path')) {
      context.handle(
        _sourcePathMeta,
        sourcePath.isAcceptableOrUnknown(data['source_path']!, _sourcePathMeta),
      );
    }
    if (data.containsKey('source_kind')) {
      context.handle(
        _sourceKindMeta,
        sourceKind.isAcceptableOrUnknown(data['source_kind']!, _sourceKindMeta),
      );
    }
    if (data.containsKey('source_page')) {
      context.handle(
        _sourcePageMeta,
        sourcePage.isAcceptableOrUnknown(data['source_page']!, _sourcePageMeta),
      );
    }
    if (data.containsKey('page_image_path')) {
      context.handle(
        _pageImagePathMeta,
        pageImagePath.isAcceptableOrUnknown(
          data['page_image_path']!,
          _pageImagePathMeta,
        ),
      );
    }
    if (data.containsKey('slice_path')) {
      context.handle(
        _slicePathMeta,
        slicePath.isAcceptableOrUnknown(data['slice_path']!, _slicePathMeta),
      );
    }
    if (data.containsKey('slice_width')) {
      context.handle(
        _sliceWidthMeta,
        sliceWidth.isAcceptableOrUnknown(data['slice_width']!, _sliceWidthMeta),
      );
    }
    if (data.containsKey('slice_height')) {
      context.handle(
        _sliceHeightMeta,
        sliceHeight.isAcceptableOrUnknown(
          data['slice_height']!,
          _sliceHeightMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbQuestion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbQuestion(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      folderIds: $QuestionsTable.$converterfolderIds.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}folder_ids'],
        )!,
      ),
      examId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exam_id'],
      ),
      knowledgeIds: $QuestionsTable.$converterknowledgeIds.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}knowledge_ids'],
        )!,
      ),
      errorTypes: $QuestionsTable.$convertererrorTypes.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}error_types'],
        )!,
      ),
      customErrorTypes: $QuestionsTable.$convertercustomErrorTypes.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}custom_error_types'],
        )!,
      ),
      tags: $QuestionsTable.$convertertags.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}tags'],
        )!,
      ),
      answer: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}answer'],
      ),
      explanation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}explanation'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      reviewCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}review_count'],
      )!,
      isOrganized: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_organized'],
      )!,
      isDemo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_demo'],
      )!,
      isFavorite: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_favorite'],
      )!,
      isArchived: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_archived'],
      )!,
      reviewJoined: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}review_joined'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      sliceKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}slice_kind'],
      )!,
      sliceText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}slice_text'],
      )!,
      sourcePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_path'],
      ),
      sourceKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_kind'],
      ),
      sourcePage: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_page'],
      ),
      pageImagePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_image_path'],
      ),
      slicePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}slice_path'],
      ),
      sliceWidth: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}slice_width'],
      ),
      sliceHeight: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}slice_height'],
      ),
    );
  }

  @override
  $QuestionsTable createAlias(String alias) {
    return $QuestionsTable(attachedDatabase, alias);
  }

  static TypeConverter<List<String>, String> $converterfolderIds =
      const StringListConverter();
  static TypeConverter<List<String>, String> $converterknowledgeIds =
      const StringListConverter();
  static TypeConverter<List<String>, String> $convertererrorTypes =
      const StringListConverter();
  static TypeConverter<List<String>, String> $convertercustomErrorTypes =
      const StringListConverter();
  static TypeConverter<List<String>, String> $convertertags =
      const StringListConverter();
}

class DbQuestion extends DataClass implements Insertable<DbQuestion> {
  final String id;
  final String title;
  final String subjectId;
  final List<String> folderIds;
  final String? examId;
  final List<String> knowledgeIds;
  final List<String> errorTypes;
  final List<String> customErrorTypes;
  final List<String> tags;
  final String? answer;
  final String? explanation;
  final String? notes;
  final int reviewCount;
  final int isOrganized;
  final int isDemo;
  final int isFavorite;
  final int isArchived;
  final int reviewJoined;
  final int createdAt;
  final String sliceKind;
  final String sliceText;
  final String? sourcePath;
  final String? sourceKind;
  final int? sourcePage;
  final String? pageImagePath;
  final String? slicePath;
  final int? sliceWidth;
  final int? sliceHeight;
  const DbQuestion({
    required this.id,
    required this.title,
    required this.subjectId,
    required this.folderIds,
    this.examId,
    required this.knowledgeIds,
    required this.errorTypes,
    required this.customErrorTypes,
    required this.tags,
    this.answer,
    this.explanation,
    this.notes,
    required this.reviewCount,
    required this.isOrganized,
    required this.isDemo,
    required this.isFavorite,
    required this.isArchived,
    required this.reviewJoined,
    required this.createdAt,
    required this.sliceKind,
    required this.sliceText,
    this.sourcePath,
    this.sourceKind,
    this.sourcePage,
    this.pageImagePath,
    this.slicePath,
    this.sliceWidth,
    this.sliceHeight,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['subject_id'] = Variable<String>(subjectId);
    {
      map['folder_ids'] = Variable<String>(
        $QuestionsTable.$converterfolderIds.toSql(folderIds),
      );
    }
    if (!nullToAbsent || examId != null) {
      map['exam_id'] = Variable<String>(examId);
    }
    {
      map['knowledge_ids'] = Variable<String>(
        $QuestionsTable.$converterknowledgeIds.toSql(knowledgeIds),
      );
    }
    {
      map['error_types'] = Variable<String>(
        $QuestionsTable.$convertererrorTypes.toSql(errorTypes),
      );
    }
    {
      map['custom_error_types'] = Variable<String>(
        $QuestionsTable.$convertercustomErrorTypes.toSql(customErrorTypes),
      );
    }
    {
      map['tags'] = Variable<String>(
        $QuestionsTable.$convertertags.toSql(tags),
      );
    }
    if (!nullToAbsent || answer != null) {
      map['answer'] = Variable<String>(answer);
    }
    if (!nullToAbsent || explanation != null) {
      map['explanation'] = Variable<String>(explanation);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['review_count'] = Variable<int>(reviewCount);
    map['is_organized'] = Variable<int>(isOrganized);
    map['is_demo'] = Variable<int>(isDemo);
    map['is_favorite'] = Variable<int>(isFavorite);
    map['is_archived'] = Variable<int>(isArchived);
    map['review_joined'] = Variable<int>(reviewJoined);
    map['created_at'] = Variable<int>(createdAt);
    map['slice_kind'] = Variable<String>(sliceKind);
    map['slice_text'] = Variable<String>(sliceText);
    if (!nullToAbsent || sourcePath != null) {
      map['source_path'] = Variable<String>(sourcePath);
    }
    if (!nullToAbsent || sourceKind != null) {
      map['source_kind'] = Variable<String>(sourceKind);
    }
    if (!nullToAbsent || sourcePage != null) {
      map['source_page'] = Variable<int>(sourcePage);
    }
    if (!nullToAbsent || pageImagePath != null) {
      map['page_image_path'] = Variable<String>(pageImagePath);
    }
    if (!nullToAbsent || slicePath != null) {
      map['slice_path'] = Variable<String>(slicePath);
    }
    if (!nullToAbsent || sliceWidth != null) {
      map['slice_width'] = Variable<int>(sliceWidth);
    }
    if (!nullToAbsent || sliceHeight != null) {
      map['slice_height'] = Variable<int>(sliceHeight);
    }
    return map;
  }

  QuestionsCompanion toCompanion(bool nullToAbsent) {
    return QuestionsCompanion(
      id: Value(id),
      title: Value(title),
      subjectId: Value(subjectId),
      folderIds: Value(folderIds),
      examId: examId == null && nullToAbsent
          ? const Value.absent()
          : Value(examId),
      knowledgeIds: Value(knowledgeIds),
      errorTypes: Value(errorTypes),
      customErrorTypes: Value(customErrorTypes),
      tags: Value(tags),
      answer: answer == null && nullToAbsent
          ? const Value.absent()
          : Value(answer),
      explanation: explanation == null && nullToAbsent
          ? const Value.absent()
          : Value(explanation),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      reviewCount: Value(reviewCount),
      isOrganized: Value(isOrganized),
      isDemo: Value(isDemo),
      isFavorite: Value(isFavorite),
      isArchived: Value(isArchived),
      reviewJoined: Value(reviewJoined),
      createdAt: Value(createdAt),
      sliceKind: Value(sliceKind),
      sliceText: Value(sliceText),
      sourcePath: sourcePath == null && nullToAbsent
          ? const Value.absent()
          : Value(sourcePath),
      sourceKind: sourceKind == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceKind),
      sourcePage: sourcePage == null && nullToAbsent
          ? const Value.absent()
          : Value(sourcePage),
      pageImagePath: pageImagePath == null && nullToAbsent
          ? const Value.absent()
          : Value(pageImagePath),
      slicePath: slicePath == null && nullToAbsent
          ? const Value.absent()
          : Value(slicePath),
      sliceWidth: sliceWidth == null && nullToAbsent
          ? const Value.absent()
          : Value(sliceWidth),
      sliceHeight: sliceHeight == null && nullToAbsent
          ? const Value.absent()
          : Value(sliceHeight),
    );
  }

  factory DbQuestion.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbQuestion(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      folderIds: serializer.fromJson<List<String>>(json['folderIds']),
      examId: serializer.fromJson<String?>(json['examId']),
      knowledgeIds: serializer.fromJson<List<String>>(json['knowledgeIds']),
      errorTypes: serializer.fromJson<List<String>>(json['errorTypes']),
      customErrorTypes: serializer.fromJson<List<String>>(
        json['customErrorTypes'],
      ),
      tags: serializer.fromJson<List<String>>(json['tags']),
      answer: serializer.fromJson<String?>(json['answer']),
      explanation: serializer.fromJson<String?>(json['explanation']),
      notes: serializer.fromJson<String?>(json['notes']),
      reviewCount: serializer.fromJson<int>(json['reviewCount']),
      isOrganized: serializer.fromJson<int>(json['isOrganized']),
      isDemo: serializer.fromJson<int>(json['isDemo']),
      isFavorite: serializer.fromJson<int>(json['isFavorite']),
      isArchived: serializer.fromJson<int>(json['isArchived']),
      reviewJoined: serializer.fromJson<int>(json['reviewJoined']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      sliceKind: serializer.fromJson<String>(json['sliceKind']),
      sliceText: serializer.fromJson<String>(json['sliceText']),
      sourcePath: serializer.fromJson<String?>(json['sourcePath']),
      sourceKind: serializer.fromJson<String?>(json['sourceKind']),
      sourcePage: serializer.fromJson<int?>(json['sourcePage']),
      pageImagePath: serializer.fromJson<String?>(json['pageImagePath']),
      slicePath: serializer.fromJson<String?>(json['slicePath']),
      sliceWidth: serializer.fromJson<int?>(json['sliceWidth']),
      sliceHeight: serializer.fromJson<int?>(json['sliceHeight']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'subjectId': serializer.toJson<String>(subjectId),
      'folderIds': serializer.toJson<List<String>>(folderIds),
      'examId': serializer.toJson<String?>(examId),
      'knowledgeIds': serializer.toJson<List<String>>(knowledgeIds),
      'errorTypes': serializer.toJson<List<String>>(errorTypes),
      'customErrorTypes': serializer.toJson<List<String>>(customErrorTypes),
      'tags': serializer.toJson<List<String>>(tags),
      'answer': serializer.toJson<String?>(answer),
      'explanation': serializer.toJson<String?>(explanation),
      'notes': serializer.toJson<String?>(notes),
      'reviewCount': serializer.toJson<int>(reviewCount),
      'isOrganized': serializer.toJson<int>(isOrganized),
      'isDemo': serializer.toJson<int>(isDemo),
      'isFavorite': serializer.toJson<int>(isFavorite),
      'isArchived': serializer.toJson<int>(isArchived),
      'reviewJoined': serializer.toJson<int>(reviewJoined),
      'createdAt': serializer.toJson<int>(createdAt),
      'sliceKind': serializer.toJson<String>(sliceKind),
      'sliceText': serializer.toJson<String>(sliceText),
      'sourcePath': serializer.toJson<String?>(sourcePath),
      'sourceKind': serializer.toJson<String?>(sourceKind),
      'sourcePage': serializer.toJson<int?>(sourcePage),
      'pageImagePath': serializer.toJson<String?>(pageImagePath),
      'slicePath': serializer.toJson<String?>(slicePath),
      'sliceWidth': serializer.toJson<int?>(sliceWidth),
      'sliceHeight': serializer.toJson<int?>(sliceHeight),
    };
  }

  DbQuestion copyWith({
    String? id,
    String? title,
    String? subjectId,
    List<String>? folderIds,
    Value<String?> examId = const Value.absent(),
    List<String>? knowledgeIds,
    List<String>? errorTypes,
    List<String>? customErrorTypes,
    List<String>? tags,
    Value<String?> answer = const Value.absent(),
    Value<String?> explanation = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    int? reviewCount,
    int? isOrganized,
    int? isDemo,
    int? isFavorite,
    int? isArchived,
    int? reviewJoined,
    int? createdAt,
    String? sliceKind,
    String? sliceText,
    Value<String?> sourcePath = const Value.absent(),
    Value<String?> sourceKind = const Value.absent(),
    Value<int?> sourcePage = const Value.absent(),
    Value<String?> pageImagePath = const Value.absent(),
    Value<String?> slicePath = const Value.absent(),
    Value<int?> sliceWidth = const Value.absent(),
    Value<int?> sliceHeight = const Value.absent(),
  }) => DbQuestion(
    id: id ?? this.id,
    title: title ?? this.title,
    subjectId: subjectId ?? this.subjectId,
    folderIds: folderIds ?? this.folderIds,
    examId: examId.present ? examId.value : this.examId,
    knowledgeIds: knowledgeIds ?? this.knowledgeIds,
    errorTypes: errorTypes ?? this.errorTypes,
    customErrorTypes: customErrorTypes ?? this.customErrorTypes,
    tags: tags ?? this.tags,
    answer: answer.present ? answer.value : this.answer,
    explanation: explanation.present ? explanation.value : this.explanation,
    notes: notes.present ? notes.value : this.notes,
    reviewCount: reviewCount ?? this.reviewCount,
    isOrganized: isOrganized ?? this.isOrganized,
    isDemo: isDemo ?? this.isDemo,
    isFavorite: isFavorite ?? this.isFavorite,
    isArchived: isArchived ?? this.isArchived,
    reviewJoined: reviewJoined ?? this.reviewJoined,
    createdAt: createdAt ?? this.createdAt,
    sliceKind: sliceKind ?? this.sliceKind,
    sliceText: sliceText ?? this.sliceText,
    sourcePath: sourcePath.present ? sourcePath.value : this.sourcePath,
    sourceKind: sourceKind.present ? sourceKind.value : this.sourceKind,
    sourcePage: sourcePage.present ? sourcePage.value : this.sourcePage,
    pageImagePath: pageImagePath.present
        ? pageImagePath.value
        : this.pageImagePath,
    slicePath: slicePath.present ? slicePath.value : this.slicePath,
    sliceWidth: sliceWidth.present ? sliceWidth.value : this.sliceWidth,
    sliceHeight: sliceHeight.present ? sliceHeight.value : this.sliceHeight,
  );
  DbQuestion copyWithCompanion(QuestionsCompanion data) {
    return DbQuestion(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      folderIds: data.folderIds.present ? data.folderIds.value : this.folderIds,
      examId: data.examId.present ? data.examId.value : this.examId,
      knowledgeIds: data.knowledgeIds.present
          ? data.knowledgeIds.value
          : this.knowledgeIds,
      errorTypes: data.errorTypes.present
          ? data.errorTypes.value
          : this.errorTypes,
      customErrorTypes: data.customErrorTypes.present
          ? data.customErrorTypes.value
          : this.customErrorTypes,
      tags: data.tags.present ? data.tags.value : this.tags,
      answer: data.answer.present ? data.answer.value : this.answer,
      explanation: data.explanation.present
          ? data.explanation.value
          : this.explanation,
      notes: data.notes.present ? data.notes.value : this.notes,
      reviewCount: data.reviewCount.present
          ? data.reviewCount.value
          : this.reviewCount,
      isOrganized: data.isOrganized.present
          ? data.isOrganized.value
          : this.isOrganized,
      isDemo: data.isDemo.present ? data.isDemo.value : this.isDemo,
      isFavorite: data.isFavorite.present
          ? data.isFavorite.value
          : this.isFavorite,
      isArchived: data.isArchived.present
          ? data.isArchived.value
          : this.isArchived,
      reviewJoined: data.reviewJoined.present
          ? data.reviewJoined.value
          : this.reviewJoined,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      sliceKind: data.sliceKind.present ? data.sliceKind.value : this.sliceKind,
      sliceText: data.sliceText.present ? data.sliceText.value : this.sliceText,
      sourcePath: data.sourcePath.present
          ? data.sourcePath.value
          : this.sourcePath,
      sourceKind: data.sourceKind.present
          ? data.sourceKind.value
          : this.sourceKind,
      sourcePage: data.sourcePage.present
          ? data.sourcePage.value
          : this.sourcePage,
      pageImagePath: data.pageImagePath.present
          ? data.pageImagePath.value
          : this.pageImagePath,
      slicePath: data.slicePath.present ? data.slicePath.value : this.slicePath,
      sliceWidth: data.sliceWidth.present
          ? data.sliceWidth.value
          : this.sliceWidth,
      sliceHeight: data.sliceHeight.present
          ? data.sliceHeight.value
          : this.sliceHeight,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbQuestion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('subjectId: $subjectId, ')
          ..write('folderIds: $folderIds, ')
          ..write('examId: $examId, ')
          ..write('knowledgeIds: $knowledgeIds, ')
          ..write('errorTypes: $errorTypes, ')
          ..write('customErrorTypes: $customErrorTypes, ')
          ..write('tags: $tags, ')
          ..write('answer: $answer, ')
          ..write('explanation: $explanation, ')
          ..write('notes: $notes, ')
          ..write('reviewCount: $reviewCount, ')
          ..write('isOrganized: $isOrganized, ')
          ..write('isDemo: $isDemo, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('isArchived: $isArchived, ')
          ..write('reviewJoined: $reviewJoined, ')
          ..write('createdAt: $createdAt, ')
          ..write('sliceKind: $sliceKind, ')
          ..write('sliceText: $sliceText, ')
          ..write('sourcePath: $sourcePath, ')
          ..write('sourceKind: $sourceKind, ')
          ..write('sourcePage: $sourcePage, ')
          ..write('pageImagePath: $pageImagePath, ')
          ..write('slicePath: $slicePath, ')
          ..write('sliceWidth: $sliceWidth, ')
          ..write('sliceHeight: $sliceHeight')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    title,
    subjectId,
    folderIds,
    examId,
    knowledgeIds,
    errorTypes,
    customErrorTypes,
    tags,
    answer,
    explanation,
    notes,
    reviewCount,
    isOrganized,
    isDemo,
    isFavorite,
    isArchived,
    reviewJoined,
    createdAt,
    sliceKind,
    sliceText,
    sourcePath,
    sourceKind,
    sourcePage,
    pageImagePath,
    slicePath,
    sliceWidth,
    sliceHeight,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbQuestion &&
          other.id == this.id &&
          other.title == this.title &&
          other.subjectId == this.subjectId &&
          other.folderIds == this.folderIds &&
          other.examId == this.examId &&
          other.knowledgeIds == this.knowledgeIds &&
          other.errorTypes == this.errorTypes &&
          other.customErrorTypes == this.customErrorTypes &&
          other.tags == this.tags &&
          other.answer == this.answer &&
          other.explanation == this.explanation &&
          other.notes == this.notes &&
          other.reviewCount == this.reviewCount &&
          other.isOrganized == this.isOrganized &&
          other.isDemo == this.isDemo &&
          other.isFavorite == this.isFavorite &&
          other.isArchived == this.isArchived &&
          other.reviewJoined == this.reviewJoined &&
          other.createdAt == this.createdAt &&
          other.sliceKind == this.sliceKind &&
          other.sliceText == this.sliceText &&
          other.sourcePath == this.sourcePath &&
          other.sourceKind == this.sourceKind &&
          other.sourcePage == this.sourcePage &&
          other.pageImagePath == this.pageImagePath &&
          other.slicePath == this.slicePath &&
          other.sliceWidth == this.sliceWidth &&
          other.sliceHeight == this.sliceHeight);
}

class QuestionsCompanion extends UpdateCompanion<DbQuestion> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> subjectId;
  final Value<List<String>> folderIds;
  final Value<String?> examId;
  final Value<List<String>> knowledgeIds;
  final Value<List<String>> errorTypes;
  final Value<List<String>> customErrorTypes;
  final Value<List<String>> tags;
  final Value<String?> answer;
  final Value<String?> explanation;
  final Value<String?> notes;
  final Value<int> reviewCount;
  final Value<int> isOrganized;
  final Value<int> isDemo;
  final Value<int> isFavorite;
  final Value<int> isArchived;
  final Value<int> reviewJoined;
  final Value<int> createdAt;
  final Value<String> sliceKind;
  final Value<String> sliceText;
  final Value<String?> sourcePath;
  final Value<String?> sourceKind;
  final Value<int?> sourcePage;
  final Value<String?> pageImagePath;
  final Value<String?> slicePath;
  final Value<int?> sliceWidth;
  final Value<int?> sliceHeight;
  final Value<int> rowid;
  const QuestionsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.folderIds = const Value.absent(),
    this.examId = const Value.absent(),
    this.knowledgeIds = const Value.absent(),
    this.errorTypes = const Value.absent(),
    this.customErrorTypes = const Value.absent(),
    this.tags = const Value.absent(),
    this.answer = const Value.absent(),
    this.explanation = const Value.absent(),
    this.notes = const Value.absent(),
    this.reviewCount = const Value.absent(),
    this.isOrganized = const Value.absent(),
    this.isDemo = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.isArchived = const Value.absent(),
    this.reviewJoined = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.sliceKind = const Value.absent(),
    this.sliceText = const Value.absent(),
    this.sourcePath = const Value.absent(),
    this.sourceKind = const Value.absent(),
    this.sourcePage = const Value.absent(),
    this.pageImagePath = const Value.absent(),
    this.slicePath = const Value.absent(),
    this.sliceWidth = const Value.absent(),
    this.sliceHeight = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QuestionsCompanion.insert({
    required String id,
    required String title,
    required String subjectId,
    this.folderIds = const Value.absent(),
    this.examId = const Value.absent(),
    this.knowledgeIds = const Value.absent(),
    this.errorTypes = const Value.absent(),
    this.customErrorTypes = const Value.absent(),
    this.tags = const Value.absent(),
    this.answer = const Value.absent(),
    this.explanation = const Value.absent(),
    this.notes = const Value.absent(),
    this.reviewCount = const Value.absent(),
    this.isOrganized = const Value.absent(),
    this.isDemo = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.isArchived = const Value.absent(),
    this.reviewJoined = const Value.absent(),
    required int createdAt,
    this.sliceKind = const Value.absent(),
    this.sliceText = const Value.absent(),
    this.sourcePath = const Value.absent(),
    this.sourceKind = const Value.absent(),
    this.sourcePage = const Value.absent(),
    this.pageImagePath = const Value.absent(),
    this.slicePath = const Value.absent(),
    this.sliceWidth = const Value.absent(),
    this.sliceHeight = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       subjectId = Value(subjectId),
       createdAt = Value(createdAt);
  static Insertable<DbQuestion> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? subjectId,
    Expression<String>? folderIds,
    Expression<String>? examId,
    Expression<String>? knowledgeIds,
    Expression<String>? errorTypes,
    Expression<String>? customErrorTypes,
    Expression<String>? tags,
    Expression<String>? answer,
    Expression<String>? explanation,
    Expression<String>? notes,
    Expression<int>? reviewCount,
    Expression<int>? isOrganized,
    Expression<int>? isDemo,
    Expression<int>? isFavorite,
    Expression<int>? isArchived,
    Expression<int>? reviewJoined,
    Expression<int>? createdAt,
    Expression<String>? sliceKind,
    Expression<String>? sliceText,
    Expression<String>? sourcePath,
    Expression<String>? sourceKind,
    Expression<int>? sourcePage,
    Expression<String>? pageImagePath,
    Expression<String>? slicePath,
    Expression<int>? sliceWidth,
    Expression<int>? sliceHeight,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (subjectId != null) 'subject_id': subjectId,
      if (folderIds != null) 'folder_ids': folderIds,
      if (examId != null) 'exam_id': examId,
      if (knowledgeIds != null) 'knowledge_ids': knowledgeIds,
      if (errorTypes != null) 'error_types': errorTypes,
      if (customErrorTypes != null) 'custom_error_types': customErrorTypes,
      if (tags != null) 'tags': tags,
      if (answer != null) 'answer': answer,
      if (explanation != null) 'explanation': explanation,
      if (notes != null) 'notes': notes,
      if (reviewCount != null) 'review_count': reviewCount,
      if (isOrganized != null) 'is_organized': isOrganized,
      if (isDemo != null) 'is_demo': isDemo,
      if (isFavorite != null) 'is_favorite': isFavorite,
      if (isArchived != null) 'is_archived': isArchived,
      if (reviewJoined != null) 'review_joined': reviewJoined,
      if (createdAt != null) 'created_at': createdAt,
      if (sliceKind != null) 'slice_kind': sliceKind,
      if (sliceText != null) 'slice_text': sliceText,
      if (sourcePath != null) 'source_path': sourcePath,
      if (sourceKind != null) 'source_kind': sourceKind,
      if (sourcePage != null) 'source_page': sourcePage,
      if (pageImagePath != null) 'page_image_path': pageImagePath,
      if (slicePath != null) 'slice_path': slicePath,
      if (sliceWidth != null) 'slice_width': sliceWidth,
      if (sliceHeight != null) 'slice_height': sliceHeight,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QuestionsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? subjectId,
    Value<List<String>>? folderIds,
    Value<String?>? examId,
    Value<List<String>>? knowledgeIds,
    Value<List<String>>? errorTypes,
    Value<List<String>>? customErrorTypes,
    Value<List<String>>? tags,
    Value<String?>? answer,
    Value<String?>? explanation,
    Value<String?>? notes,
    Value<int>? reviewCount,
    Value<int>? isOrganized,
    Value<int>? isDemo,
    Value<int>? isFavorite,
    Value<int>? isArchived,
    Value<int>? reviewJoined,
    Value<int>? createdAt,
    Value<String>? sliceKind,
    Value<String>? sliceText,
    Value<String?>? sourcePath,
    Value<String?>? sourceKind,
    Value<int?>? sourcePage,
    Value<String?>? pageImagePath,
    Value<String?>? slicePath,
    Value<int?>? sliceWidth,
    Value<int?>? sliceHeight,
    Value<int>? rowid,
  }) {
    return QuestionsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      subjectId: subjectId ?? this.subjectId,
      folderIds: folderIds ?? this.folderIds,
      examId: examId ?? this.examId,
      knowledgeIds: knowledgeIds ?? this.knowledgeIds,
      errorTypes: errorTypes ?? this.errorTypes,
      customErrorTypes: customErrorTypes ?? this.customErrorTypes,
      tags: tags ?? this.tags,
      answer: answer ?? this.answer,
      explanation: explanation ?? this.explanation,
      notes: notes ?? this.notes,
      reviewCount: reviewCount ?? this.reviewCount,
      isOrganized: isOrganized ?? this.isOrganized,
      isDemo: isDemo ?? this.isDemo,
      isFavorite: isFavorite ?? this.isFavorite,
      isArchived: isArchived ?? this.isArchived,
      reviewJoined: reviewJoined ?? this.reviewJoined,
      createdAt: createdAt ?? this.createdAt,
      sliceKind: sliceKind ?? this.sliceKind,
      sliceText: sliceText ?? this.sliceText,
      sourcePath: sourcePath ?? this.sourcePath,
      sourceKind: sourceKind ?? this.sourceKind,
      sourcePage: sourcePage ?? this.sourcePage,
      pageImagePath: pageImagePath ?? this.pageImagePath,
      slicePath: slicePath ?? this.slicePath,
      sliceWidth: sliceWidth ?? this.sliceWidth,
      sliceHeight: sliceHeight ?? this.sliceHeight,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (folderIds.present) {
      map['folder_ids'] = Variable<String>(
        $QuestionsTable.$converterfolderIds.toSql(folderIds.value),
      );
    }
    if (examId.present) {
      map['exam_id'] = Variable<String>(examId.value);
    }
    if (knowledgeIds.present) {
      map['knowledge_ids'] = Variable<String>(
        $QuestionsTable.$converterknowledgeIds.toSql(knowledgeIds.value),
      );
    }
    if (errorTypes.present) {
      map['error_types'] = Variable<String>(
        $QuestionsTable.$convertererrorTypes.toSql(errorTypes.value),
      );
    }
    if (customErrorTypes.present) {
      map['custom_error_types'] = Variable<String>(
        $QuestionsTable.$convertercustomErrorTypes.toSql(
          customErrorTypes.value,
        ),
      );
    }
    if (tags.present) {
      map['tags'] = Variable<String>(
        $QuestionsTable.$convertertags.toSql(tags.value),
      );
    }
    if (answer.present) {
      map['answer'] = Variable<String>(answer.value);
    }
    if (explanation.present) {
      map['explanation'] = Variable<String>(explanation.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (reviewCount.present) {
      map['review_count'] = Variable<int>(reviewCount.value);
    }
    if (isOrganized.present) {
      map['is_organized'] = Variable<int>(isOrganized.value);
    }
    if (isDemo.present) {
      map['is_demo'] = Variable<int>(isDemo.value);
    }
    if (isFavorite.present) {
      map['is_favorite'] = Variable<int>(isFavorite.value);
    }
    if (isArchived.present) {
      map['is_archived'] = Variable<int>(isArchived.value);
    }
    if (reviewJoined.present) {
      map['review_joined'] = Variable<int>(reviewJoined.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (sliceKind.present) {
      map['slice_kind'] = Variable<String>(sliceKind.value);
    }
    if (sliceText.present) {
      map['slice_text'] = Variable<String>(sliceText.value);
    }
    if (sourcePath.present) {
      map['source_path'] = Variable<String>(sourcePath.value);
    }
    if (sourceKind.present) {
      map['source_kind'] = Variable<String>(sourceKind.value);
    }
    if (sourcePage.present) {
      map['source_page'] = Variable<int>(sourcePage.value);
    }
    if (pageImagePath.present) {
      map['page_image_path'] = Variable<String>(pageImagePath.value);
    }
    if (slicePath.present) {
      map['slice_path'] = Variable<String>(slicePath.value);
    }
    if (sliceWidth.present) {
      map['slice_width'] = Variable<int>(sliceWidth.value);
    }
    if (sliceHeight.present) {
      map['slice_height'] = Variable<int>(sliceHeight.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuestionsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('subjectId: $subjectId, ')
          ..write('folderIds: $folderIds, ')
          ..write('examId: $examId, ')
          ..write('knowledgeIds: $knowledgeIds, ')
          ..write('errorTypes: $errorTypes, ')
          ..write('customErrorTypes: $customErrorTypes, ')
          ..write('tags: $tags, ')
          ..write('answer: $answer, ')
          ..write('explanation: $explanation, ')
          ..write('notes: $notes, ')
          ..write('reviewCount: $reviewCount, ')
          ..write('isOrganized: $isOrganized, ')
          ..write('isDemo: $isDemo, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('isArchived: $isArchived, ')
          ..write('reviewJoined: $reviewJoined, ')
          ..write('createdAt: $createdAt, ')
          ..write('sliceKind: $sliceKind, ')
          ..write('sliceText: $sliceText, ')
          ..write('sourcePath: $sourcePath, ')
          ..write('sourceKind: $sourceKind, ')
          ..write('sourcePage: $sourcePage, ')
          ..write('pageImagePath: $pageImagePath, ')
          ..write('slicePath: $slicePath, ')
          ..write('sliceWidth: $sliceWidth, ')
          ..write('sliceHeight: $sliceHeight, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$QuizDatabase extends GeneratedDatabase {
  _$QuizDatabase(QueryExecutor e) : super(e);
  $QuizDatabaseManager get managers => $QuizDatabaseManager(this);
  late final $SettingsTable settings = $SettingsTable(this);
  late final $TagsTable tags = $TagsTable(this);
  late final $ExamsTable exams = $ExamsTable(this);
  late final $KnowledgePointsTable knowledgePoints = $KnowledgePointsTable(
    this,
  );
  late final $FoldersTable folders = $FoldersTable(this);
  late final $SubjectsTable subjects = $SubjectsTable(this);
  late final $RecentTasksTable recentTasks = $RecentTasksTable(this);
  late final $RecentlyViewedQuestionsTable recentlyViewedQuestions =
      $RecentlyViewedQuestionsTable(this);
  late final $ReviewHistoryTable reviewHistory = $ReviewHistoryTable(this);
  late final $CauseRecordsTable causeRecords = $CauseRecordsTable(this);
  late final $ReviewStateTable reviewState = $ReviewStateTable(this);
  late final $CollectTasksTable collectTasks = $CollectTasksTable(this);
  late final $QuestionBoxesTable questionBoxes = $QuestionBoxesTable(this);
  late final $QuestionsTable questions = $QuestionsTable(this);
  late final Index idxBoxesTaskPage = Index(
    'idx_boxes_task_page',
    'CREATE INDEX idx_boxes_task_page ON question_boxes (collect_task_id, page)',
  );
  late final Index idxBoxesQuestion = Index(
    'idx_boxes_question',
    'CREATE INDEX idx_boxes_question ON question_boxes (question_id)',
  );
  late final Index idxBoxesParent = Index(
    'idx_boxes_parent',
    'CREATE INDEX idx_boxes_parent ON question_boxes (parent_box_id)',
  );
  late final Index idxBoxesOneLayer1PerQuestion = Index(
    'idx_boxes_one_layer1_per_question',
    'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes (question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    settings,
    tags,
    exams,
    knowledgePoints,
    folders,
    subjects,
    recentTasks,
    recentlyViewedQuestions,
    reviewHistory,
    causeRecords,
    reviewState,
    collectTasks,
    questionBoxes,
    questions,
    idxBoxesTaskPage,
    idxBoxesQuestion,
    idxBoxesParent,
    idxBoxesOneLayer1PerQuestion,
  ];
}

typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$QuizDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$QuizDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $SettingsTable,
          DbSetting,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            DbSetting,
            BaseReferences<_$QuizDatabase, $SettingsTable, DbSetting>,
          ),
          DbSetting,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$QuizDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, DbSetting>(table),
                  BaseReferences<_$QuizDatabase, $SettingsTable, DbSetting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $SettingsTable,
      DbSetting,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (DbSetting, BaseReferences<_$QuizDatabase, $SettingsTable, DbSetting>),
      DbSetting,
      PrefetchHooks Function()
    >;
typedef $$TagsTableCreateCompanionBuilder = TagsCompanion Function({
  required String id,
  required String name,
  Value<int> rowid,
});
typedef $$TagsTableUpdateCompanionBuilder = TagsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<int> rowid,
});

class $$TagsTableFilterComposer extends Composer<_$QuizDatabase, $TagsTable> {
  $$TagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TagsTableOrderingComposer extends Composer<_$QuizDatabase, $TagsTable> {
  $$TagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TagsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $TagsTable> {
  $$TagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);
}

class $$TagsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $TagsTable,
          DbTag,
          $$TagsTableFilterComposer,
          $$TagsTableOrderingComposer,
          $$TagsTableAnnotationComposer,
          $$TagsTableCreateCompanionBuilder,
          $$TagsTableUpdateCompanionBuilder,
          (DbTag, BaseReferences<_$QuizDatabase, $TagsTable, DbTag>),
          DbTag,
          PrefetchHooks Function()
        > {
  $$TagsTableTableManager(_$QuizDatabase db, $TagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => TagsCompanion(id: id, name: name, rowid: rowid),
          createCompanionCallback: ({
            required String id,
            required String name,
            Value<int> rowid = const Value.absent(),
          }) => TagsCompanion.insert(id: id, name: name, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TagsTable, DbTag>(table),
                  BaseReferences<_$QuizDatabase, $TagsTable, DbTag>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TagsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $TagsTable,
      DbTag,
      $$TagsTableFilterComposer,
      $$TagsTableOrderingComposer,
      $$TagsTableAnnotationComposer,
      $$TagsTableCreateCompanionBuilder,
      $$TagsTableUpdateCompanionBuilder,
      (DbTag, BaseReferences<_$QuizDatabase, $TagsTable, DbTag>),
      DbTag,
      PrefetchHooks Function()
    >;
typedef $$ExamsTableCreateCompanionBuilder = ExamsCompanion Function({
  required String id,
  required String name,
  Value<int?> date,
  Value<int> rowid,
});
typedef $$ExamsTableUpdateCompanionBuilder = ExamsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<int?> date,
  Value<int> rowid,
});

class $$ExamsTableFilterComposer extends Composer<_$QuizDatabase, $ExamsTable> {
  $$ExamsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ExamsTableOrderingComposer
    extends Composer<_$QuizDatabase, $ExamsTable> {
  $$ExamsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ExamsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $ExamsTable> {
  $$ExamsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);
}

class $$ExamsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $ExamsTable,
          DbExam,
          $$ExamsTableFilterComposer,
          $$ExamsTableOrderingComposer,
          $$ExamsTableAnnotationComposer,
          $$ExamsTableCreateCompanionBuilder,
          $$ExamsTableUpdateCompanionBuilder,
          (DbExam, BaseReferences<_$QuizDatabase, $ExamsTable, DbExam>),
          DbExam,
          PrefetchHooks Function()
        > {
  $$ExamsTableTableManager(_$QuizDatabase db, $ExamsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExamsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExamsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExamsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int?> date = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => ExamsCompanion(id: id, name: name, date: date, rowid: rowid),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int?> date = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ExamsCompanion.insert(
                id: id,
                name: name,
                date: date,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ExamsTable, DbExam>(table),
                  BaseReferences<_$QuizDatabase, $ExamsTable, DbExam>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ExamsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $ExamsTable,
      DbExam,
      $$ExamsTableFilterComposer,
      $$ExamsTableOrderingComposer,
      $$ExamsTableAnnotationComposer,
      $$ExamsTableCreateCompanionBuilder,
      $$ExamsTableUpdateCompanionBuilder,
      (DbExam, BaseReferences<_$QuizDatabase, $ExamsTable, DbExam>),
      DbExam,
      PrefetchHooks Function()
    >;
typedef $$KnowledgePointsTableCreateCompanionBuilder =
    KnowledgePointsCompanion Function({
      required String id,
      required String subjectId,
      required String chapter,
      required String name,
      Value<int> rowid,
    });
typedef $$KnowledgePointsTableUpdateCompanionBuilder =
    KnowledgePointsCompanion Function({
      Value<String> id,
      Value<String> subjectId,
      Value<String> chapter,
      Value<String> name,
      Value<int> rowid,
    });

class $$KnowledgePointsTableFilterComposer
    extends Composer<_$QuizDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnowledgePointsTableOrderingComposer
    extends Composer<_$QuizDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnowledgePointsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $KnowledgePointsTable> {
  $$KnowledgePointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<String> get chapter =>
      $composableBuilder(column: $table.chapter, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);
}

class $$KnowledgePointsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $KnowledgePointsTable,
          DbKnowledgePoint,
          $$KnowledgePointsTableFilterComposer,
          $$KnowledgePointsTableOrderingComposer,
          $$KnowledgePointsTableAnnotationComposer,
          $$KnowledgePointsTableCreateCompanionBuilder,
          $$KnowledgePointsTableUpdateCompanionBuilder,
          (
            DbKnowledgePoint,
            BaseReferences<
              _$QuizDatabase,
              $KnowledgePointsTable,
              DbKnowledgePoint
            >,
          ),
          DbKnowledgePoint,
          PrefetchHooks Function()
        > {
  $$KnowledgePointsTableTableManager(
    _$QuizDatabase db,
    $KnowledgePointsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnowledgePointsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnowledgePointsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnowledgePointsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String> chapter = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnowledgePointsCompanion(
                id: id,
                subjectId: subjectId,
                chapter: chapter,
                name: name,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String subjectId,
                required String chapter,
                required String name,
                Value<int> rowid = const Value.absent(),
              }) => KnowledgePointsCompanion.insert(
                id: id,
                subjectId: subjectId,
                chapter: chapter,
                name: name,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnowledgePointsTable, DbKnowledgePoint>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $KnowledgePointsTable,
                    DbKnowledgePoint
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnowledgePointsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $KnowledgePointsTable,
      DbKnowledgePoint,
      $$KnowledgePointsTableFilterComposer,
      $$KnowledgePointsTableOrderingComposer,
      $$KnowledgePointsTableAnnotationComposer,
      $$KnowledgePointsTableCreateCompanionBuilder,
      $$KnowledgePointsTableUpdateCompanionBuilder,
      (
        DbKnowledgePoint,
        BaseReferences<_$QuizDatabase, $KnowledgePointsTable, DbKnowledgePoint>,
      ),
      DbKnowledgePoint,
      PrefetchHooks Function()
    >;
typedef $$FoldersTableCreateCompanionBuilder = FoldersCompanion Function({
  required String id,
  required String name,
  required String subjectId,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});
typedef $$FoldersTableUpdateCompanionBuilder = FoldersCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> subjectId,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});

class $$FoldersTableFilterComposer
    extends Composer<_$QuizDatabase, $FoldersTable> {
  $$FoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FoldersTableOrderingComposer
    extends Composer<_$QuizDatabase, $FoldersTable> {
  $$FoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FoldersTableAnnotationComposer
    extends Composer<_$QuizDatabase, $FoldersTable> {
  $$FoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$FoldersTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $FoldersTable,
          DbFolder,
          $$FoldersTableFilterComposer,
          $$FoldersTableOrderingComposer,
          $$FoldersTableAnnotationComposer,
          $$FoldersTableCreateCompanionBuilder,
          $$FoldersTableUpdateCompanionBuilder,
          (DbFolder, BaseReferences<_$QuizDatabase, $FoldersTable, DbFolder>),
          DbFolder,
          PrefetchHooks Function()
        > {
  $$FoldersTableTableManager(_$QuizDatabase db, $FoldersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion(
                id: id,
                name: name,
                subjectId: subjectId,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String subjectId,
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion.insert(
                id: id,
                name: name,
                subjectId: subjectId,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FoldersTable, DbFolder>(table),
                  BaseReferences<_$QuizDatabase, $FoldersTable, DbFolder>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $FoldersTable,
      DbFolder,
      $$FoldersTableFilterComposer,
      $$FoldersTableOrderingComposer,
      $$FoldersTableAnnotationComposer,
      $$FoldersTableCreateCompanionBuilder,
      $$FoldersTableUpdateCompanionBuilder,
      (DbFolder, BaseReferences<_$QuizDatabase, $FoldersTable, DbFolder>),
      DbFolder,
      PrefetchHooks Function()
    >;
typedef $$SubjectsTableCreateCompanionBuilder = SubjectsCompanion Function({
  required String id,
  required String name,
  required int color,
  Value<String> coverStyle,
  Value<String> coverColor,
  Value<int> rowid,
});
typedef $$SubjectsTableUpdateCompanionBuilder = SubjectsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<int> color,
  Value<String> coverStyle,
  Value<String> coverColor,
  Value<int> rowid,
});

class $$SubjectsTableFilterComposer
    extends Composer<_$QuizDatabase, $SubjectsTable> {
  $$SubjectsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverStyle => $composableBuilder(
    column: $table.coverStyle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverColor => $composableBuilder(
    column: $table.coverColor,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SubjectsTableOrderingComposer
    extends Composer<_$QuizDatabase, $SubjectsTable> {
  $$SubjectsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverStyle => $composableBuilder(
    column: $table.coverStyle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverColor => $composableBuilder(
    column: $table.coverColor,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SubjectsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $SubjectsTable> {
  $$SubjectsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get coverStyle => $composableBuilder(
    column: $table.coverStyle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get coverColor => $composableBuilder(
    column: $table.coverColor,
    builder: (column) => column,
  );
}

class $$SubjectsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $SubjectsTable,
          DbSubject,
          $$SubjectsTableFilterComposer,
          $$SubjectsTableOrderingComposer,
          $$SubjectsTableAnnotationComposer,
          $$SubjectsTableCreateCompanionBuilder,
          $$SubjectsTableUpdateCompanionBuilder,
          (
            DbSubject,
            BaseReferences<_$QuizDatabase, $SubjectsTable, DbSubject>,
          ),
          DbSubject,
          PrefetchHooks Function()
        > {
  $$SubjectsTableTableManager(_$QuizDatabase db, $SubjectsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SubjectsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SubjectsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SubjectsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> color = const Value.absent(),
                Value<String> coverStyle = const Value.absent(),
                Value<String> coverColor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubjectsCompanion(
                id: id,
                name: name,
                color: color,
                coverStyle: coverStyle,
                coverColor: coverColor,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required int color,
                Value<String> coverStyle = const Value.absent(),
                Value<String> coverColor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubjectsCompanion.insert(
                id: id,
                name: name,
                color: color,
                coverStyle: coverStyle,
                coverColor: coverColor,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SubjectsTable, DbSubject>(table),
                  BaseReferences<_$QuizDatabase, $SubjectsTable, DbSubject>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SubjectsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $SubjectsTable,
      DbSubject,
      $$SubjectsTableFilterComposer,
      $$SubjectsTableOrderingComposer,
      $$SubjectsTableAnnotationComposer,
      $$SubjectsTableCreateCompanionBuilder,
      $$SubjectsTableUpdateCompanionBuilder,
      (DbSubject, BaseReferences<_$QuizDatabase, $SubjectsTable, DbSubject>),
      DbSubject,
      PrefetchHooks Function()
    >;
typedef $$RecentTasksTableCreateCompanionBuilder =
    RecentTasksCompanion Function({
      Value<int> id,
      required String kind,
      required String subjectId,
      required String title,
      required int updatedAt,
    });
typedef $$RecentTasksTableUpdateCompanionBuilder =
    RecentTasksCompanion Function({
      Value<int> id,
      Value<String> kind,
      Value<String> subjectId,
      Value<String> title,
      Value<int> updatedAt,
    });

class $$RecentTasksTableFilterComposer
    extends Composer<_$QuizDatabase, $RecentTasksTable> {
  $$RecentTasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecentTasksTableOrderingComposer
    extends Composer<_$QuizDatabase, $RecentTasksTable> {
  $$RecentTasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecentTasksTableAnnotationComposer
    extends Composer<_$QuizDatabase, $RecentTasksTable> {
  $$RecentTasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$RecentTasksTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $RecentTasksTable,
          DbRecentTask,
          $$RecentTasksTableFilterComposer,
          $$RecentTasksTableOrderingComposer,
          $$RecentTasksTableAnnotationComposer,
          $$RecentTasksTableCreateCompanionBuilder,
          $$RecentTasksTableUpdateCompanionBuilder,
          (
            DbRecentTask,
            BaseReferences<_$QuizDatabase, $RecentTasksTable, DbRecentTask>,
          ),
          DbRecentTask,
          PrefetchHooks Function()
        > {
  $$RecentTasksTableTableManager(_$QuizDatabase db, $RecentTasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecentTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecentTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecentTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => RecentTasksCompanion(
                id: id,
                kind: kind,
                subjectId: subjectId,
                title: title,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String kind,
                required String subjectId,
                required String title,
                required int updatedAt,
              }) => RecentTasksCompanion.insert(
                id: id,
                kind: kind,
                subjectId: subjectId,
                title: title,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecentTasksTable, DbRecentTask>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $RecentTasksTable,
                    DbRecentTask
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecentTasksTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $RecentTasksTable,
      DbRecentTask,
      $$RecentTasksTableFilterComposer,
      $$RecentTasksTableOrderingComposer,
      $$RecentTasksTableAnnotationComposer,
      $$RecentTasksTableCreateCompanionBuilder,
      $$RecentTasksTableUpdateCompanionBuilder,
      (
        DbRecentTask,
        BaseReferences<_$QuizDatabase, $RecentTasksTable, DbRecentTask>,
      ),
      DbRecentTask,
      PrefetchHooks Function()
    >;
typedef $$RecentlyViewedQuestionsTableCreateCompanionBuilder =
    RecentlyViewedQuestionsCompanion Function({
      required String questionId,
      required int viewedAt,
      Value<int> rowid,
    });
typedef $$RecentlyViewedQuestionsTableUpdateCompanionBuilder =
    RecentlyViewedQuestionsCompanion Function({
      Value<String> questionId,
      Value<int> viewedAt,
      Value<int> rowid,
    });

class $$RecentlyViewedQuestionsTableFilterComposer
    extends Composer<_$QuizDatabase, $RecentlyViewedQuestionsTable> {
  $$RecentlyViewedQuestionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get viewedAt => $composableBuilder(
    column: $table.viewedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecentlyViewedQuestionsTableOrderingComposer
    extends Composer<_$QuizDatabase, $RecentlyViewedQuestionsTable> {
  $$RecentlyViewedQuestionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get viewedAt => $composableBuilder(
    column: $table.viewedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecentlyViewedQuestionsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $RecentlyViewedQuestionsTable> {
  $$RecentlyViewedQuestionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get viewedAt =>
      $composableBuilder(column: $table.viewedAt, builder: (column) => column);
}

class $$RecentlyViewedQuestionsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $RecentlyViewedQuestionsTable,
          RecentlyViewedQuestion,
          $$RecentlyViewedQuestionsTableFilterComposer,
          $$RecentlyViewedQuestionsTableOrderingComposer,
          $$RecentlyViewedQuestionsTableAnnotationComposer,
          $$RecentlyViewedQuestionsTableCreateCompanionBuilder,
          $$RecentlyViewedQuestionsTableUpdateCompanionBuilder,
          (
            RecentlyViewedQuestion,
            BaseReferences<
              _$QuizDatabase,
              $RecentlyViewedQuestionsTable,
              RecentlyViewedQuestion
            >,
          ),
          RecentlyViewedQuestion,
          PrefetchHooks Function()
        > {
  $$RecentlyViewedQuestionsTableTableManager(
    _$QuizDatabase db,
    $RecentlyViewedQuestionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecentlyViewedQuestionsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$RecentlyViewedQuestionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RecentlyViewedQuestionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> questionId = const Value.absent(),
                Value<int> viewedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecentlyViewedQuestionsCompanion(
                questionId: questionId,
                viewedAt: viewedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String questionId,
                required int viewedAt,
                Value<int> rowid = const Value.absent(),
              }) => RecentlyViewedQuestionsCompanion.insert(
                questionId: questionId,
                viewedAt: viewedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $RecentlyViewedQuestionsTable,
                    RecentlyViewedQuestion
                  >(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $RecentlyViewedQuestionsTable,
                    RecentlyViewedQuestion
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecentlyViewedQuestionsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $RecentlyViewedQuestionsTable,
      RecentlyViewedQuestion,
      $$RecentlyViewedQuestionsTableFilterComposer,
      $$RecentlyViewedQuestionsTableOrderingComposer,
      $$RecentlyViewedQuestionsTableAnnotationComposer,
      $$RecentlyViewedQuestionsTableCreateCompanionBuilder,
      $$RecentlyViewedQuestionsTableUpdateCompanionBuilder,
      (
        RecentlyViewedQuestion,
        BaseReferences<
          _$QuizDatabase,
          $RecentlyViewedQuestionsTable,
          RecentlyViewedQuestion
        >,
      ),
      RecentlyViewedQuestion,
      PrefetchHooks Function()
    >;
typedef $$ReviewHistoryTableCreateCompanionBuilder =
    ReviewHistoryCompanion Function({
      Value<int> id,
      required String questionId,
      required String result,
      required int reviewedAt,
    });
typedef $$ReviewHistoryTableUpdateCompanionBuilder =
    ReviewHistoryCompanion Function({
      Value<int> id,
      Value<String> questionId,
      Value<String> result,
      Value<int> reviewedAt,
    });

class $$ReviewHistoryTableFilterComposer
    extends Composer<_$QuizDatabase, $ReviewHistoryTable> {
  $$ReviewHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReviewHistoryTableOrderingComposer
    extends Composer<_$QuizDatabase, $ReviewHistoryTable> {
  $$ReviewHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get result => $composableBuilder(
    column: $table.result,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReviewHistoryTableAnnotationComposer
    extends Composer<_$QuizDatabase, $ReviewHistoryTable> {
  $$ReviewHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get result =>
      $composableBuilder(column: $table.result, builder: (column) => column);

  GeneratedColumn<int> get reviewedAt => $composableBuilder(
    column: $table.reviewedAt,
    builder: (column) => column,
  );
}

class $$ReviewHistoryTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $ReviewHistoryTable,
          DbReviewHistory,
          $$ReviewHistoryTableFilterComposer,
          $$ReviewHistoryTableOrderingComposer,
          $$ReviewHistoryTableAnnotationComposer,
          $$ReviewHistoryTableCreateCompanionBuilder,
          $$ReviewHistoryTableUpdateCompanionBuilder,
          (
            DbReviewHistory,
            BaseReferences<
              _$QuizDatabase,
              $ReviewHistoryTable,
              DbReviewHistory
            >,
          ),
          DbReviewHistory,
          PrefetchHooks Function()
        > {
  $$ReviewHistoryTableTableManager(_$QuizDatabase db, $ReviewHistoryTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReviewHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReviewHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReviewHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> questionId = const Value.absent(),
                Value<String> result = const Value.absent(),
                Value<int> reviewedAt = const Value.absent(),
              }) => ReviewHistoryCompanion(
                id: id,
                questionId: questionId,
                result: result,
                reviewedAt: reviewedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String questionId,
                required String result,
                required int reviewedAt,
              }) => ReviewHistoryCompanion.insert(
                id: id,
                questionId: questionId,
                result: result,
                reviewedAt: reviewedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReviewHistoryTable, DbReviewHistory>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $ReviewHistoryTable,
                    DbReviewHistory
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReviewHistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $ReviewHistoryTable,
      DbReviewHistory,
      $$ReviewHistoryTableFilterComposer,
      $$ReviewHistoryTableOrderingComposer,
      $$ReviewHistoryTableAnnotationComposer,
      $$ReviewHistoryTableCreateCompanionBuilder,
      $$ReviewHistoryTableUpdateCompanionBuilder,
      (
        DbReviewHistory,
        BaseReferences<_$QuizDatabase, $ReviewHistoryTable, DbReviewHistory>,
      ),
      DbReviewHistory,
      PrefetchHooks Function()
    >;
typedef $$CauseRecordsTableCreateCompanionBuilder =
    CauseRecordsCompanion Function({
      Value<int> id,
      required String questionId,
      required String cause,
      required String subjectId,
      Value<String> status,
      Value<int> solvedCount,
      Value<int?> lastCheck,
      Value<int?> recheckDate,
      Value<List<String>> remedyHistory,
      required int joinedAt,
    });
typedef $$CauseRecordsTableUpdateCompanionBuilder =
    CauseRecordsCompanion Function({
      Value<int> id,
      Value<String> questionId,
      Value<String> cause,
      Value<String> subjectId,
      Value<String> status,
      Value<int> solvedCount,
      Value<int?> lastCheck,
      Value<int?> recheckDate,
      Value<List<String>> remedyHistory,
      Value<int> joinedAt,
    });

class $$CauseRecordsTableFilterComposer
    extends Composer<_$QuizDatabase, $CauseRecordsTable> {
  $$CauseRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cause => $composableBuilder(
    column: $table.cause,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get solvedCount => $composableBuilder(
    column: $table.solvedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastCheck => $composableBuilder(
    column: $table.lastCheck,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recheckDate => $composableBuilder(
    column: $table.recheckDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get remedyHistory => $composableBuilder(
    column: $table.remedyHistory,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CauseRecordsTableOrderingComposer
    extends Composer<_$QuizDatabase, $CauseRecordsTable> {
  $$CauseRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cause => $composableBuilder(
    column: $table.cause,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get solvedCount => $composableBuilder(
    column: $table.solvedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastCheck => $composableBuilder(
    column: $table.lastCheck,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recheckDate => $composableBuilder(
    column: $table.recheckDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remedyHistory => $composableBuilder(
    column: $table.remedyHistory,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CauseRecordsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $CauseRecordsTable> {
  $$CauseRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cause =>
      $composableBuilder(column: $table.cause, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get solvedCount => $composableBuilder(
    column: $table.solvedCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastCheck =>
      $composableBuilder(column: $table.lastCheck, builder: (column) => column);

  GeneratedColumn<int> get recheckDate => $composableBuilder(
    column: $table.recheckDate,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<List<String>, String> get remedyHistory =>
      $composableBuilder(
        column: $table.remedyHistory,
        builder: (column) => column,
      );

  GeneratedColumn<int> get joinedAt =>
      $composableBuilder(column: $table.joinedAt, builder: (column) => column);
}

class $$CauseRecordsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $CauseRecordsTable,
          DbCauseRecord,
          $$CauseRecordsTableFilterComposer,
          $$CauseRecordsTableOrderingComposer,
          $$CauseRecordsTableAnnotationComposer,
          $$CauseRecordsTableCreateCompanionBuilder,
          $$CauseRecordsTableUpdateCompanionBuilder,
          (
            DbCauseRecord,
            BaseReferences<_$QuizDatabase, $CauseRecordsTable, DbCauseRecord>,
          ),
          DbCauseRecord,
          PrefetchHooks Function()
        > {
  $$CauseRecordsTableTableManager(_$QuizDatabase db, $CauseRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CauseRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CauseRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CauseRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> questionId = const Value.absent(),
                Value<String> cause = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> solvedCount = const Value.absent(),
                Value<int?> lastCheck = const Value.absent(),
                Value<int?> recheckDate = const Value.absent(),
                Value<List<String>> remedyHistory = const Value.absent(),
                Value<int> joinedAt = const Value.absent(),
              }) => CauseRecordsCompanion(
                id: id,
                questionId: questionId,
                cause: cause,
                subjectId: subjectId,
                status: status,
                solvedCount: solvedCount,
                lastCheck: lastCheck,
                recheckDate: recheckDate,
                remedyHistory: remedyHistory,
                joinedAt: joinedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String questionId,
                required String cause,
                required String subjectId,
                Value<String> status = const Value.absent(),
                Value<int> solvedCount = const Value.absent(),
                Value<int?> lastCheck = const Value.absent(),
                Value<int?> recheckDate = const Value.absent(),
                Value<List<String>> remedyHistory = const Value.absent(),
                required int joinedAt,
              }) => CauseRecordsCompanion.insert(
                id: id,
                questionId: questionId,
                cause: cause,
                subjectId: subjectId,
                status: status,
                solvedCount: solvedCount,
                lastCheck: lastCheck,
                recheckDate: recheckDate,
                remedyHistory: remedyHistory,
                joinedAt: joinedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CauseRecordsTable, DbCauseRecord>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $CauseRecordsTable,
                    DbCauseRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CauseRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $CauseRecordsTable,
      DbCauseRecord,
      $$CauseRecordsTableFilterComposer,
      $$CauseRecordsTableOrderingComposer,
      $$CauseRecordsTableAnnotationComposer,
      $$CauseRecordsTableCreateCompanionBuilder,
      $$CauseRecordsTableUpdateCompanionBuilder,
      (
        DbCauseRecord,
        BaseReferences<_$QuizDatabase, $CauseRecordsTable, DbCauseRecord>,
      ),
      DbCauseRecord,
      PrefetchHooks Function()
    >;
typedef $$ReviewStateTableCreateCompanionBuilder =
    ReviewStateCompanion Function({
      Value<int> id,
      Value<List<ReviewQueueItem>> queue,
      Value<int> position,
      required int updatedAt,
    });
typedef $$ReviewStateTableUpdateCompanionBuilder =
    ReviewStateCompanion Function({
      Value<int> id,
      Value<List<ReviewQueueItem>> queue,
      Value<int> position,
      Value<int> updatedAt,
    });

class $$ReviewStateTableFilterComposer
    extends Composer<_$QuizDatabase, $ReviewStateTable> {
  $$ReviewStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    List<ReviewQueueItem>,
    List<ReviewQueueItem>,
    String
  >
  get queue => $composableBuilder(
    column: $table.queue,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReviewStateTableOrderingComposer
    extends Composer<_$QuizDatabase, $ReviewStateTable> {
  $$ReviewStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queue => $composableBuilder(
    column: $table.queue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReviewStateTableAnnotationComposer
    extends Composer<_$QuizDatabase, $ReviewStateTable> {
  $$ReviewStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<ReviewQueueItem>, String> get queue =>
      $composableBuilder(column: $table.queue, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ReviewStateTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $ReviewStateTable,
          DbReviewState,
          $$ReviewStateTableFilterComposer,
          $$ReviewStateTableOrderingComposer,
          $$ReviewStateTableAnnotationComposer,
          $$ReviewStateTableCreateCompanionBuilder,
          $$ReviewStateTableUpdateCompanionBuilder,
          (
            DbReviewState,
            BaseReferences<_$QuizDatabase, $ReviewStateTable, DbReviewState>,
          ),
          DbReviewState,
          PrefetchHooks Function()
        > {
  $$ReviewStateTableTableManager(_$QuizDatabase db, $ReviewStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReviewStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReviewStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReviewStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<List<ReviewQueueItem>> queue = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => ReviewStateCompanion(
                id: id,
                queue: queue,
                position: position,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<List<ReviewQueueItem>> queue = const Value.absent(),
                Value<int> position = const Value.absent(),
                required int updatedAt,
              }) => ReviewStateCompanion.insert(
                id: id,
                queue: queue,
                position: position,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReviewStateTable, DbReviewState>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $ReviewStateTable,
                    DbReviewState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReviewStateTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $ReviewStateTable,
      DbReviewState,
      $$ReviewStateTableFilterComposer,
      $$ReviewStateTableOrderingComposer,
      $$ReviewStateTableAnnotationComposer,
      $$ReviewStateTableCreateCompanionBuilder,
      $$ReviewStateTableUpdateCompanionBuilder,
      (
        DbReviewState,
        BaseReferences<_$QuizDatabase, $ReviewStateTable, DbReviewState>,
      ),
      DbReviewState,
      PrefetchHooks Function()
    >;
typedef $$CollectTasksTableCreateCompanionBuilder =
    CollectTasksCompanion Function({
      required String id,
      required String name,
      required String fileName,
      required String subjectId,
      Value<String> status,
      Value<int> progress,
      Value<int> pageCount,
      Value<int> page,
      Value<String?> error,
      Value<String?> questionId,
      Value<int> createdAt,
      Value<String> sourcePath,
      Value<Map<int, int>> pageRotations,
      Value<String?> sourceHash,
      Value<int> rowid,
    });
typedef $$CollectTasksTableUpdateCompanionBuilder =
    CollectTasksCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> fileName,
      Value<String> subjectId,
      Value<String> status,
      Value<int> progress,
      Value<int> pageCount,
      Value<int> page,
      Value<String?> error,
      Value<String?> questionId,
      Value<int> createdAt,
      Value<String> sourcePath,
      Value<Map<int, int>> pageRotations,
      Value<String?> sourceHash,
      Value<int> rowid,
    });

class $$CollectTasksTableFilterComposer
    extends Composer<_$QuizDatabase, $CollectTasksTable> {
  $$CollectTasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<Map<int, int>, Map<int, int>, String>
  get pageRotations => $composableBuilder(
    column: $table.pageRotations,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get sourceHash => $composableBuilder(
    column: $table.sourceHash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CollectTasksTableOrderingComposer
    extends Composer<_$QuizDatabase, $CollectTasksTable> {
  $$CollectTasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pageRotations => $composableBuilder(
    column: $table.pageRotations,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceHash => $composableBuilder(
    column: $table.sourceHash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CollectTasksTableAnnotationComposer
    extends Composer<_$QuizDatabase, $CollectTasksTable> {
  $$CollectTasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<int> get pageCount =>
      $composableBuilder(column: $table.pageCount, builder: (column) => column);

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<Map<int, int>, String> get pageRotations =>
      $composableBuilder(
        column: $table.pageRotations,
        builder: (column) => column,
      );

  GeneratedColumn<String> get sourceHash => $composableBuilder(
    column: $table.sourceHash,
    builder: (column) => column,
  );
}

class $$CollectTasksTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $CollectTasksTable,
          DbCollectTask,
          $$CollectTasksTableFilterComposer,
          $$CollectTasksTableOrderingComposer,
          $$CollectTasksTableAnnotationComposer,
          $$CollectTasksTableCreateCompanionBuilder,
          $$CollectTasksTableUpdateCompanionBuilder,
          (
            DbCollectTask,
            BaseReferences<_$QuizDatabase, $CollectTasksTable, DbCollectTask>,
          ),
          DbCollectTask,
          PrefetchHooks Function()
        > {
  $$CollectTasksTableTableManager(_$QuizDatabase db, $CollectTasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CollectTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CollectTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CollectTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> progress = const Value.absent(),
                Value<int> pageCount = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<String?> questionId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> sourcePath = const Value.absent(),
                Value<Map<int, int>> pageRotations = const Value.absent(),
                Value<String?> sourceHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CollectTasksCompanion(
                id: id,
                name: name,
                fileName: fileName,
                subjectId: subjectId,
                status: status,
                progress: progress,
                pageCount: pageCount,
                page: page,
                error: error,
                questionId: questionId,
                createdAt: createdAt,
                sourcePath: sourcePath,
                pageRotations: pageRotations,
                sourceHash: sourceHash,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String fileName,
                required String subjectId,
                Value<String> status = const Value.absent(),
                Value<int> progress = const Value.absent(),
                Value<int> pageCount = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<String?> questionId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> sourcePath = const Value.absent(),
                Value<Map<int, int>> pageRotations = const Value.absent(),
                Value<String?> sourceHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CollectTasksCompanion.insert(
                id: id,
                name: name,
                fileName: fileName,
                subjectId: subjectId,
                status: status,
                progress: progress,
                pageCount: pageCount,
                page: page,
                error: error,
                questionId: questionId,
                createdAt: createdAt,
                sourcePath: sourcePath,
                pageRotations: pageRotations,
                sourceHash: sourceHash,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CollectTasksTable, DbCollectTask>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $CollectTasksTable,
                    DbCollectTask
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CollectTasksTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $CollectTasksTable,
      DbCollectTask,
      $$CollectTasksTableFilterComposer,
      $$CollectTasksTableOrderingComposer,
      $$CollectTasksTableAnnotationComposer,
      $$CollectTasksTableCreateCompanionBuilder,
      $$CollectTasksTableUpdateCompanionBuilder,
      (
        DbCollectTask,
        BaseReferences<_$QuizDatabase, $CollectTasksTable, DbCollectTask>,
      ),
      DbCollectTask,
      PrefetchHooks Function()
    >;
typedef $$QuestionBoxesTableCreateCompanionBuilder =
    QuestionBoxesCompanion Function({
      required String id,
      Value<String?> collectTaskId,
      Value<String?> questionId,
      Value<String?> parentBoxId,
      Value<int> page,
      required int layer,
      required String type,
      required double x,
      required double y,
      required double w,
      required double h,
      Value<double?> confidence,
      Value<String> origin,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$QuestionBoxesTableUpdateCompanionBuilder =
    QuestionBoxesCompanion Function({
      Value<String> id,
      Value<String?> collectTaskId,
      Value<String?> questionId,
      Value<String?> parentBoxId,
      Value<int> page,
      Value<int> layer,
      Value<String> type,
      Value<double> x,
      Value<double> y,
      Value<double> w,
      Value<double> h,
      Value<double?> confidence,
      Value<String> origin,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$QuestionBoxesTableFilterComposer
    extends Composer<_$QuizDatabase, $QuestionBoxesTable> {
  $$QuestionBoxesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get collectTaskId => $composableBuilder(
    column: $table.collectTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentBoxId => $composableBuilder(
    column: $table.parentBoxId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get layer => $composableBuilder(
    column: $table.layer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QuestionBoxesTableOrderingComposer
    extends Composer<_$QuizDatabase, $QuestionBoxesTable> {
  $$QuestionBoxesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get collectTaskId => $composableBuilder(
    column: $table.collectTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentBoxId => $composableBuilder(
    column: $table.parentBoxId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get layer => $composableBuilder(
    column: $table.layer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuestionBoxesTableAnnotationComposer
    extends Composer<_$QuizDatabase, $QuestionBoxesTable> {
  $$QuestionBoxesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get collectTaskId => $composableBuilder(
    column: $table.collectTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get parentBoxId => $composableBuilder(
    column: $table.parentBoxId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<int> get layer =>
      $composableBuilder(column: $table.layer, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<double> get x =>
      $composableBuilder(column: $table.x, builder: (column) => column);

  GeneratedColumn<double> get y =>
      $composableBuilder(column: $table.y, builder: (column) => column);

  GeneratedColumn<double> get w =>
      $composableBuilder(column: $table.w, builder: (column) => column);

  GeneratedColumn<double> get h =>
      $composableBuilder(column: $table.h, builder: (column) => column);

  GeneratedColumn<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => column,
  );

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$QuestionBoxesTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $QuestionBoxesTable,
          DbQuestionBox,
          $$QuestionBoxesTableFilterComposer,
          $$QuestionBoxesTableOrderingComposer,
          $$QuestionBoxesTableAnnotationComposer,
          $$QuestionBoxesTableCreateCompanionBuilder,
          $$QuestionBoxesTableUpdateCompanionBuilder,
          (
            DbQuestionBox,
            BaseReferences<_$QuizDatabase, $QuestionBoxesTable, DbQuestionBox>,
          ),
          DbQuestionBox,
          PrefetchHooks Function()
        > {
  $$QuestionBoxesTableTableManager(_$QuizDatabase db, $QuestionBoxesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuestionBoxesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuestionBoxesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuestionBoxesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> collectTaskId = const Value.absent(),
                Value<String?> questionId = const Value.absent(),
                Value<String?> parentBoxId = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<int> layer = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<double> x = const Value.absent(),
                Value<double> y = const Value.absent(),
                Value<double> w = const Value.absent(),
                Value<double> h = const Value.absent(),
                Value<double?> confidence = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionBoxesCompanion(
                id: id,
                collectTaskId: collectTaskId,
                questionId: questionId,
                parentBoxId: parentBoxId,
                page: page,
                layer: layer,
                type: type,
                x: x,
                y: y,
                w: w,
                h: h,
                confidence: confidence,
                origin: origin,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> collectTaskId = const Value.absent(),
                Value<String?> questionId = const Value.absent(),
                Value<String?> parentBoxId = const Value.absent(),
                Value<int> page = const Value.absent(),
                required int layer,
                required String type,
                required double x,
                required double y,
                required double w,
                required double h,
                Value<double?> confidence = const Value.absent(),
                Value<String> origin = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => QuestionBoxesCompanion.insert(
                id: id,
                collectTaskId: collectTaskId,
                questionId: questionId,
                parentBoxId: parentBoxId,
                page: page,
                layer: layer,
                type: type,
                x: x,
                y: y,
                w: w,
                h: h,
                confidence: confidence,
                origin: origin,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$QuestionBoxesTable, DbQuestionBox>(table),
                  BaseReferences<
                    _$QuizDatabase,
                    $QuestionBoxesTable,
                    DbQuestionBox
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QuestionBoxesTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $QuestionBoxesTable,
      DbQuestionBox,
      $$QuestionBoxesTableFilterComposer,
      $$QuestionBoxesTableOrderingComposer,
      $$QuestionBoxesTableAnnotationComposer,
      $$QuestionBoxesTableCreateCompanionBuilder,
      $$QuestionBoxesTableUpdateCompanionBuilder,
      (
        DbQuestionBox,
        BaseReferences<_$QuizDatabase, $QuestionBoxesTable, DbQuestionBox>,
      ),
      DbQuestionBox,
      PrefetchHooks Function()
    >;
typedef $$QuestionsTableCreateCompanionBuilder = QuestionsCompanion Function({
  required String id,
  required String title,
  required String subjectId,
  Value<List<String>> folderIds,
  Value<String?> examId,
  Value<List<String>> knowledgeIds,
  Value<List<String>> errorTypes,
  Value<List<String>> customErrorTypes,
  Value<List<String>> tags,
  Value<String?> answer,
  Value<String?> explanation,
  Value<String?> notes,
  Value<int> reviewCount,
  Value<int> isOrganized,
  Value<int> isDemo,
  Value<int> isFavorite,
  Value<int> isArchived,
  Value<int> reviewJoined,
  required int createdAt,
  Value<String> sliceKind,
  Value<String> sliceText,
  Value<String?> sourcePath,
  Value<String?> sourceKind,
  Value<int?> sourcePage,
  Value<String?> pageImagePath,
  Value<String?> slicePath,
  Value<int?> sliceWidth,
  Value<int?> sliceHeight,
  Value<int> rowid,
});
typedef $$QuestionsTableUpdateCompanionBuilder = QuestionsCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> subjectId,
  Value<List<String>> folderIds,
  Value<String?> examId,
  Value<List<String>> knowledgeIds,
  Value<List<String>> errorTypes,
  Value<List<String>> customErrorTypes,
  Value<List<String>> tags,
  Value<String?> answer,
  Value<String?> explanation,
  Value<String?> notes,
  Value<int> reviewCount,
  Value<int> isOrganized,
  Value<int> isDemo,
  Value<int> isFavorite,
  Value<int> isArchived,
  Value<int> reviewJoined,
  Value<int> createdAt,
  Value<String> sliceKind,
  Value<String> sliceText,
  Value<String?> sourcePath,
  Value<String?> sourceKind,
  Value<int?> sourcePage,
  Value<String?> pageImagePath,
  Value<String?> slicePath,
  Value<int?> sliceWidth,
  Value<int?> sliceHeight,
  Value<int> rowid,
});

class $$QuestionsTableFilterComposer
    extends Composer<_$QuizDatabase, $QuestionsTable> {
  $$QuestionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get folderIds => $composableBuilder(
    column: $table.folderIds,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get examId => $composableBuilder(
    column: $table.examId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get knowledgeIds => $composableBuilder(
    column: $table.knowledgeIds,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get errorTypes => $composableBuilder(
    column: $table.errorTypes,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get customErrorTypes => $composableBuilder(
    column: $table.customErrorTypes,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String> get tags =>
      $composableBuilder(
        column: $table.tags,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get answer => $composableBuilder(
    column: $table.answer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewCount => $composableBuilder(
    column: $table.reviewCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isOrganized => $composableBuilder(
    column: $table.isOrganized,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isDemo => $composableBuilder(
    column: $table.isDemo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewJoined => $composableBuilder(
    column: $table.reviewJoined,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sliceKind => $composableBuilder(
    column: $table.sliceKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sliceText => $composableBuilder(
    column: $table.sliceText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceKind => $composableBuilder(
    column: $table.sourceKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pageImagePath => $composableBuilder(
    column: $table.pageImagePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get slicePath => $composableBuilder(
    column: $table.slicePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sliceWidth => $composableBuilder(
    column: $table.sliceWidth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sliceHeight => $composableBuilder(
    column: $table.sliceHeight,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QuestionsTableOrderingComposer
    extends Composer<_$QuizDatabase, $QuestionsTable> {
  $$QuestionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderIds => $composableBuilder(
    column: $table.folderIds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get examId => $composableBuilder(
    column: $table.examId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get knowledgeIds => $composableBuilder(
    column: $table.knowledgeIds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorTypes => $composableBuilder(
    column: $table.errorTypes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customErrorTypes => $composableBuilder(
    column: $table.customErrorTypes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get answer => $composableBuilder(
    column: $table.answer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewCount => $composableBuilder(
    column: $table.reviewCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isOrganized => $composableBuilder(
    column: $table.isOrganized,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isDemo => $composableBuilder(
    column: $table.isDemo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewJoined => $composableBuilder(
    column: $table.reviewJoined,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sliceKind => $composableBuilder(
    column: $table.sliceKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sliceText => $composableBuilder(
    column: $table.sliceText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceKind => $composableBuilder(
    column: $table.sourceKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pageImagePath => $composableBuilder(
    column: $table.pageImagePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get slicePath => $composableBuilder(
    column: $table.slicePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sliceWidth => $composableBuilder(
    column: $table.sliceWidth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sliceHeight => $composableBuilder(
    column: $table.sliceHeight,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuestionsTableAnnotationComposer
    extends Composer<_$QuizDatabase, $QuestionsTable> {
  $$QuestionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<String>, String> get folderIds =>
      $composableBuilder(column: $table.folderIds, builder: (column) => column);

  GeneratedColumn<String> get examId =>
      $composableBuilder(column: $table.examId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<String>, String> get knowledgeIds =>
      $composableBuilder(
        column: $table.knowledgeIds,
        builder: (column) => column,
      );

  GeneratedColumnWithTypeConverter<List<String>, String> get errorTypes =>
      $composableBuilder(
        column: $table.errorTypes,
        builder: (column) => column,
      );

  GeneratedColumnWithTypeConverter<List<String>, String> get customErrorTypes =>
      $composableBuilder(
        column: $table.customErrorTypes,
        builder: (column) => column,
      );

  GeneratedColumnWithTypeConverter<List<String>, String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get answer =>
      $composableBuilder(column: $table.answer, builder: (column) => column);

  GeneratedColumn<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get reviewCount => $composableBuilder(
    column: $table.reviewCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get isOrganized => $composableBuilder(
    column: $table.isOrganized,
    builder: (column) => column,
  );

  GeneratedColumn<int> get isDemo =>
      $composableBuilder(column: $table.isDemo, builder: (column) => column);

  GeneratedColumn<int> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => column,
  );

  GeneratedColumn<int> get isArchived => $composableBuilder(
    column: $table.isArchived,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reviewJoined => $composableBuilder(
    column: $table.reviewJoined,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get sliceKind =>
      $composableBuilder(column: $table.sliceKind, builder: (column) => column);

  GeneratedColumn<String> get sliceText =>
      $composableBuilder(column: $table.sliceText, builder: (column) => column);

  GeneratedColumn<String> get sourcePath => $composableBuilder(
    column: $table.sourcePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceKind => $composableBuilder(
    column: $table.sourceKind,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pageImagePath => $composableBuilder(
    column: $table.pageImagePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get slicePath =>
      $composableBuilder(column: $table.slicePath, builder: (column) => column);

  GeneratedColumn<int> get sliceWidth => $composableBuilder(
    column: $table.sliceWidth,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sliceHeight => $composableBuilder(
    column: $table.sliceHeight,
    builder: (column) => column,
  );
}

class $$QuestionsTableTableManager
    extends
        RootTableManager<
          _$QuizDatabase,
          $QuestionsTable,
          DbQuestion,
          $$QuestionsTableFilterComposer,
          $$QuestionsTableOrderingComposer,
          $$QuestionsTableAnnotationComposer,
          $$QuestionsTableCreateCompanionBuilder,
          $$QuestionsTableUpdateCompanionBuilder,
          (
            DbQuestion,
            BaseReferences<_$QuizDatabase, $QuestionsTable, DbQuestion>,
          ),
          DbQuestion,
          PrefetchHooks Function()
        > {
  $$QuestionsTableTableManager(_$QuizDatabase db, $QuestionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuestionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuestionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuestionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<List<String>> folderIds = const Value.absent(),
                Value<String?> examId = const Value.absent(),
                Value<List<String>> knowledgeIds = const Value.absent(),
                Value<List<String>> errorTypes = const Value.absent(),
                Value<List<String>> customErrorTypes = const Value.absent(),
                Value<List<String>> tags = const Value.absent(),
                Value<String?> answer = const Value.absent(),
                Value<String?> explanation = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int> reviewCount = const Value.absent(),
                Value<int> isOrganized = const Value.absent(),
                Value<int> isDemo = const Value.absent(),
                Value<int> isFavorite = const Value.absent(),
                Value<int> isArchived = const Value.absent(),
                Value<int> reviewJoined = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> sliceKind = const Value.absent(),
                Value<String> sliceText = const Value.absent(),
                Value<String?> sourcePath = const Value.absent(),
                Value<String?> sourceKind = const Value.absent(),
                Value<int?> sourcePage = const Value.absent(),
                Value<String?> pageImagePath = const Value.absent(),
                Value<String?> slicePath = const Value.absent(),
                Value<int?> sliceWidth = const Value.absent(),
                Value<int?> sliceHeight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionsCompanion(
                id: id,
                title: title,
                subjectId: subjectId,
                folderIds: folderIds,
                examId: examId,
                knowledgeIds: knowledgeIds,
                errorTypes: errorTypes,
                customErrorTypes: customErrorTypes,
                tags: tags,
                answer: answer,
                explanation: explanation,
                notes: notes,
                reviewCount: reviewCount,
                isOrganized: isOrganized,
                isDemo: isDemo,
                isFavorite: isFavorite,
                isArchived: isArchived,
                reviewJoined: reviewJoined,
                createdAt: createdAt,
                sliceKind: sliceKind,
                sliceText: sliceText,
                sourcePath: sourcePath,
                sourceKind: sourceKind,
                sourcePage: sourcePage,
                pageImagePath: pageImagePath,
                slicePath: slicePath,
                sliceWidth: sliceWidth,
                sliceHeight: sliceHeight,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String subjectId,
                Value<List<String>> folderIds = const Value.absent(),
                Value<String?> examId = const Value.absent(),
                Value<List<String>> knowledgeIds = const Value.absent(),
                Value<List<String>> errorTypes = const Value.absent(),
                Value<List<String>> customErrorTypes = const Value.absent(),
                Value<List<String>> tags = const Value.absent(),
                Value<String?> answer = const Value.absent(),
                Value<String?> explanation = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int> reviewCount = const Value.absent(),
                Value<int> isOrganized = const Value.absent(),
                Value<int> isDemo = const Value.absent(),
                Value<int> isFavorite = const Value.absent(),
                Value<int> isArchived = const Value.absent(),
                Value<int> reviewJoined = const Value.absent(),
                required int createdAt,
                Value<String> sliceKind = const Value.absent(),
                Value<String> sliceText = const Value.absent(),
                Value<String?> sourcePath = const Value.absent(),
                Value<String?> sourceKind = const Value.absent(),
                Value<int?> sourcePage = const Value.absent(),
                Value<String?> pageImagePath = const Value.absent(),
                Value<String?> slicePath = const Value.absent(),
                Value<int?> sliceWidth = const Value.absent(),
                Value<int?> sliceHeight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionsCompanion.insert(
                id: id,
                title: title,
                subjectId: subjectId,
                folderIds: folderIds,
                examId: examId,
                knowledgeIds: knowledgeIds,
                errorTypes: errorTypes,
                customErrorTypes: customErrorTypes,
                tags: tags,
                answer: answer,
                explanation: explanation,
                notes: notes,
                reviewCount: reviewCount,
                isOrganized: isOrganized,
                isDemo: isDemo,
                isFavorite: isFavorite,
                isArchived: isArchived,
                reviewJoined: reviewJoined,
                createdAt: createdAt,
                sliceKind: sliceKind,
                sliceText: sliceText,
                sourcePath: sourcePath,
                sourceKind: sourceKind,
                sourcePage: sourcePage,
                pageImagePath: pageImagePath,
                slicePath: slicePath,
                sliceWidth: sliceWidth,
                sliceHeight: sliceHeight,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$QuestionsTable, DbQuestion>(table),
                  BaseReferences<_$QuizDatabase, $QuestionsTable, DbQuestion>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QuestionsTableProcessedTableManager =
    ProcessedTableManager<
      _$QuizDatabase,
      $QuestionsTable,
      DbQuestion,
      $$QuestionsTableFilterComposer,
      $$QuestionsTableOrderingComposer,
      $$QuestionsTableAnnotationComposer,
      $$QuestionsTableCreateCompanionBuilder,
      $$QuestionsTableUpdateCompanionBuilder,
      (DbQuestion, BaseReferences<_$QuizDatabase, $QuestionsTable, DbQuestion>),
      DbQuestion,
      PrefetchHooks Function()
    >;

class $QuizDatabaseManager {
  final _$QuizDatabase _db;
  $QuizDatabaseManager(this._db);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
  $$TagsTableTableManager get tags => $$TagsTableTableManager(_db, _db.tags);
  $$ExamsTableTableManager get exams =>
      $$ExamsTableTableManager(_db, _db.exams);
  $$KnowledgePointsTableTableManager get knowledgePoints =>
      $$KnowledgePointsTableTableManager(_db, _db.knowledgePoints);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db, _db.folders);
  $$SubjectsTableTableManager get subjects =>
      $$SubjectsTableTableManager(_db, _db.subjects);
  $$RecentTasksTableTableManager get recentTasks =>
      $$RecentTasksTableTableManager(_db, _db.recentTasks);
  $$RecentlyViewedQuestionsTableTableManager get recentlyViewedQuestions =>
      $$RecentlyViewedQuestionsTableTableManager(
        _db,
        _db.recentlyViewedQuestions,
      );
  $$ReviewHistoryTableTableManager get reviewHistory =>
      $$ReviewHistoryTableTableManager(_db, _db.reviewHistory);
  $$CauseRecordsTableTableManager get causeRecords =>
      $$CauseRecordsTableTableManager(_db, _db.causeRecords);
  $$ReviewStateTableTableManager get reviewState =>
      $$ReviewStateTableTableManager(_db, _db.reviewState);
  $$CollectTasksTableTableManager get collectTasks =>
      $$CollectTasksTableTableManager(_db, _db.collectTasks);
  $$QuestionBoxesTableTableManager get questionBoxes =>
      $$QuestionBoxesTableTableManager(_db, _db.questionBoxes);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db, _db.questions);
}
