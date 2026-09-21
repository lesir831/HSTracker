import Foundation

/// Experimental layout for the inspected client runtime only. A different UUID must be
/// revalidated; using a nearby Unity version's offsets can silently fabricate progress.
public final class MonoRuntime {
    public static let supportedUUID = "07aedcd386773366a75feb184f6ac069"
    let memory: RemoteMemory
    let root: UInt64
    private var classes: [String: UInt64] = [:]
    private var fieldCache: [UInt64: [Field]] = [:]

    public init(memory: RemoteMemory, root: UInt64, uuid: String) throws {
        guard uuid == Self.supportedUUID else { throw ProbeError.unavailable("unsupportedMonoLayout: \(uuid)") }
        self.memory = memory
        self.root = root
    }

    public func prepare() throws {
        if !classes.isEmpty { return }
        try loadClasses()
    }

    private func loadClasses() throws {
        var node = try memory.uint(at: root + 0xb0)
        var seen = Set<UInt64>()
        while node != 0 {
            guard seen.insert(node).inserted, seen.count <= 512 else { throw ProbeError.invalid("Invalid assembly list") }
            let assembly = try memory.uint(at: node)
            let name = try memory.string(at: memory.uint(at: assembly + 0x10))
            if ["Assembly-CSharp", "Blizzard.T5.ServiceLocator", "Blizzard.T5.Localization"].contains(name) {
                let image = try memory.uint(at: assembly + 0x60)
                let count = try memory.uint(at: image + 0x4e8, width: 4)
                let table = try memory.uint(at: image + 0x4f0)
                guard count > 0, count <= 65536 else { throw ProbeError.invalid("Invalid Mono class table") }
                var visited = Set<UInt64>()
                for index in 0..<count {
                    var entry = try memory.uint(at: table + index * 8)
                    while entry != 0 {
                        guard visited.insert(entry).inserted, visited.count <= 100000 else {
                            throw ProbeError.invalid("Invalid Mono class chain")
                        }
                        let className = try memory.string(at: memory.uint(at: entry + 0x40))
                        let namespace = try memory.string(at: memory.uint(at: entry + 0x48))
                        classes[namespace.isEmpty ? className : namespace + "." + className] = entry
                        entry = try memory.uint(at: entry + 0x100)
                    }
                }
            }
            node = try memory.uint(at: node + 8)
        }
        guard classes["Hearthstone.Progression.QuestManager"] != nil else {
            throw ProbeError.unavailable("progressClassesNotLoaded")
        }
    }

    struct Field {
        let name: String
        let offset: UInt64
        let type: UInt64
        let isStatic: Bool
    }

    private func fields(of address: UInt64, depth: Int = 0) throws -> [Field] {
        if let cached = fieldCache[address] { return cached }
        guard depth < 16 else { throw ProbeError.invalid("Invalid class ancestry") }
        let kind = try memory.uint(at: address + 0x1b, width: 1) & 7
        let definition = kind == 3 ? try memory.uint(at: memory.uint(at: address + 0xe8)) : address
        let count = try memory.uint(at: definition + 0xf8, width: 4)
        guard count <= 1024 else { throw ProbeError.invalid("Invalid Mono field count") }
        let base = try memory.uint(at: address + 0x90)
        var result: [Field] = []
        for index in 0..<count {
            let field = base + index * 32
            let name = try memory.string(at: memory.uint(at: field + 8))
            let offset = try memory.uint(at: field + 24, width: 4)
            let type = try memory.uint(at: field)
            let attributes = try memory.uint(at: type + 8, width: 4)
            result.append(Field(name: name, offset: offset, type: (attributes >> 16) & 255,
                                isStatic: attributes & 0x10 != 0))
        }
        let parent = try memory.uint(at: address + 0x28)
        if parent != 0 { result += try fields(of: parent, depth: depth + 1) }
        fieldCache[address] = result
        return result
    }

    private func objectClass(_ object: UInt64) throws -> UInt64 {
        try memory.uint(at: memory.uint(at: object))
    }

    private func objectField(_ object: UInt64, _ name: String) throws -> UInt64 {
        guard let field = try fields(of: objectClass(object)).first(where: { $0.name == name && !$0.isStatic }) else {
            throw ProbeError.unavailable("missingField: " + name)
        }
        return object + field.offset
    }

    private func staticObject(_ className: String, _ fieldName: String) throws -> UInt64 {
        guard let address = classes[className],
              let field = try fields(of: address).first(where: { $0.name == fieldName && $0.isStatic }) else {
            throw ProbeError.unavailable("missingStaticField: " + fieldName)
        }
        let info = try memory.uint(at: address + 0xc8)
        guard info != 0 else { throw ProbeError.unavailable("staticClassNotInitialized: " + className) }
        let vtable = try memory.uint(at: info + 8)
        guard vtable != 0 else { throw ProbeError.unavailable("staticClassNotInitialized: " + className) }
        let size = try memory.uint(at: address + 0x54, width: 4)
        guard size < 4096, field.offset < 65536 else { throw ProbeError.invalid("Invalid static field layout") }
        let storage = try memory.uint(at: vtable + 0x48 + size * 8)
        guard storage != 0 else { throw ProbeError.unavailable("staticStorageNotInitialized: " + className) }
        return try memory.uint(at: storage + field.offset)
    }

    struct Entry {
        let keyAddress: UInt64
        let keyType: UInt64
        let valueAddress: UInt64
        let valueType: UInt64
    }

    private func dictionaryEntries(_ dictionary: UInt64) throws -> [Entry] {
        let version = try integer(dictionary, "_version")
        let entries = try memory.uint(at: objectField(dictionary, "_entries"))
        let count = try memory.uint(at: objectField(dictionary, "_count"), width: 4)
        if count == 0 { return [] }
        let length = try memory.uint(at: entries + 24)
        guard count <= length, length <= 100000 else { throw ProbeError.invalid("Invalid dictionary size") }
        let arrayClass = try objectClass(entries)
        let stride = try memory.uint(at: arrayClass + 0x88, width: 4)
        let entryClass = try memory.uint(at: arrayClass)
        let entryFields = try fields(of: entryClass)
        guard let hash = entryFields.first(where: { $0.name == "hashCode" }),
              let next = entryFields.first(where: { $0.name == "next" }),
              let key = entryFields.first(where: { $0.name == "key" }),
              let value = entryFields.first(where: { $0.name == "value" }),
              stride >= 16, stride <= 128,
              [hash, next, key, value].allSatisfy({ $0.offset >= 16 && $0.offset - 16 < stride }) else {
            throw ProbeError.invalid("Unsupported dictionary entry layout")
        }
        var result: [Entry] = []
        for index in 0..<count {
            let entry = entries + 32 + index * stride
            let code = try memory.uint(at: entry + hash.offset - 16, width: 4)
            let link = try memory.uint(at: entry + next.offset - 16, width: 4)
            if (hash.type == 8 && Int32(bitPattern: UInt32(code)) < 0) || Int32(bitPattern: UInt32(link)) < -1 { continue }
            result.append(Entry(keyAddress: entry + key.offset - 16, keyType: key.type,
                                valueAddress: entry + value.offset - 16, valueType: value.type))
        }
        guard try integer(dictionary, "_version") == version else { throw ProbeError.unavailable("dictionaryChangedDuringRead") }
        return result
    }

    private func dictionaryValues(_ dictionary: UInt64) throws -> [UInt64] {
        try dictionaryEntries(dictionary).map { entry in
            guard [18, 21, 28].contains(entry.valueType) else { throw ProbeError.invalid("Dictionary value is not an object") }
            let value = try memory.uint(at: entry.valueAddress)
            guard value != 0 else { throw ProbeError.unavailable("nullDictionaryValue") }
            return value
        }
    }

    private func progressServices() throws -> [String: UInt64] {
        let services = try staticObject("Blizzard.T5.Services.ServiceManager", "s_runtimeServices")
        let dictionary = try memory.uint(at: objectField(services, "m_services"))
        var result: [String: UInt64] = [:]
        for info in try dictionaryValues(dictionary) {
            let object = try memory.uint(at: objectField(info, "<Service>k__BackingField"))
            if object == 0 { continue }
            let cls = try objectClass(object)
            let name = try memory.string(at: memory.uint(at: cls + 0x40))
            if ["QuestManager", "AchievementManager"].contains(name) { result[name] = object }
        }
        return result
    }

    private func mapValues(_ map: UInt64) throws -> [UInt64] {
        let count = try memory.uint(at: objectField(map, "count"), width: 4)
        if count == 0 { return [] }
        let touched = try memory.uint(at: objectField(map, "touchedSlots"), width: 4)
        let values = try memory.uint(at: objectField(map, "valueSlots"))
        let length = try memory.uint(at: values + 24)
        guard count <= touched, touched <= length, length <= 100000 else { throw ProbeError.invalid("Invalid achievement map") }
        var result: [UInt64] = []
        for index in 0..<touched {
            let object = try memory.uint(at: values + 32 + index * 8)
            if object != 0 { result.append(object) }
        }
        guard result.count == count else { throw ProbeError.unavailable("mapChangedDuringRead") }
        return result
    }

    private func integer(_ object: UInt64, _ name: String) throws -> Int {
        let value = try memory.uint(at: objectField(object, name), width: 4)
        return Int(Int32(bitPattern: UInt32(value)))
    }

    private func progressRecord(_ object: UInt64, idField: String) throws -> [String: Int] {
        for flag in ["Has" + idField, "HasStatus", "HasProgress"] {
            guard try memory.uint(at: objectField(object, flag), width: 1) == 1 else {
                throw ProbeError.unavailable("incompleteProgressState: " + flag)
            }
        }
        let id = try integer(object, "_" + idField)
        let progress = try integer(object, "_Progress")
        let status = try integer(object, "_Status")
        guard id > 0, progress >= 0, status >= 0 else { throw ProbeError.invalid("Invalid progress record") }
        return ["id": id, "status": status, "progress": progress]
    }

    public func readQuests() throws -> [[String: Int]] {
        guard let manager = try progressServices()["QuestManager"] else { throw ProbeError.unavailable("questServiceNotReady") }
        guard try memory.uint(at: objectField(manager, "<HasReceivedQuestStatesFromServer>k__BackingField"), width: 1) == 1 else {
            throw ProbeError.unavailable("questStatesNotReceived")
        }
        let dictionary = try memory.uint(at: objectField(manager, "m_questState"))
        let version = try integer(dictionary, "_version")
        let records = try dictionaryValues(dictionary).map { try progressRecord($0, idField: "QuestId") }
        guard try integer(dictionary, "_version") == version else { throw ProbeError.unavailable("dictionaryChangedDuringRead") }
        return records
    }

    /// Read definitions from the same initialized DBF tables used by
    /// QuestManager.CreateQuestDataModel, without invoking any game method.
    public func readQuestDefinitions(ids: Set<Int>) throws -> [AccountNativeQuestDefinition] {
        guard !ids.isEmpty else { return [] }
        let locale = try currentLocaleIdentity()
        let questTable = try dbfRecords("Quest", ids: ids)
        let quests = questTable.records
        var questPools: [Int: Int] = [:]
        for (id, record) in quests {
            let pool = try integer(record, "m_questPoolId")
            guard pool >= 0 else { throw ProbeError.invalid("Invalid quest pool ID") }
            questPools[id] = pool
        }
        let poolTable = try dbfRecords("QuestPool", ids: Set(questPools.values.filter { $0 > 0 }))
        let pools = poolTable.records
        let chainIDs: Set<Int>?
        do { chainIDs = try readQuestChainIDs() }
        catch ProbeError.unavailable { chainIDs = nil }
        var localeIndex: Int?
        let definitions = try quests.keys.sorted().map { id in
            guard let record = quests[id], let poolID = questPools[id] else {
                throw ProbeError.invalid("Inconsistent quest definition join")
            }
            let quota = try integer(record, "m_quota")
            let rewardTrack = try integer(record, "m_rewardTrackType")
            guard quota >= 0, rewardTrack >= 0 else { throw ProbeError.invalid("Invalid quest definition") }
            var poolType: Int?
            if let pool = pools[poolID] {
                let raw = try integer(pool, "m_questPoolType")
                guard raw >= 0 else { throw ProbeError.invalid("Invalid quest pool type") }
                poolType = raw // Preserve future enum values for conservative callers.
            }
            return AccountNativeQuestDefinition(id: id,
                name: try localizedDbfString(memory.uint(at: objectField(record, "m_name")), localeIndex: &localeIndex),
                description: try localizedDbfString(memory.uint(at: objectField(record, "m_description")), localeIndex: &localeIndex),
                quota: quota, rewardTrackType: rewardTrack, questPoolID: poolID, poolType: poolType,
                isChainQuest: chainIDs.map { $0.contains(id) })
        }
        // Definitions and pool classification must come from one stable set of
        // tables. Locale changes reload localized DBF data independently.
        try verifyDbfSnapshot(questTable, tableName: "Quest")
        try verifyDbfSnapshot(poolTable, tableName: "QuestPool")
        let finalLocale = try currentLocaleIdentity()
        guard finalLocale.object == locale.object, finalLocale.value == locale.value else {
            throw ProbeError.unavailable("questLocaleChangedDuringRead")
        }
        return definitions
    }

    /// InitializeQuestAssets adds both ends of every link to m_chainQuestIds
    /// and stores the same links in m_chainQuestIdToPrevious. Reading both keys
    /// and values also recognizes the last step, whose NextInChain is zero.
    /// This describes membership only; it never assigns a future quest.
    private func readQuestChainIDs() throws -> Set<Int>? {
        guard let manager = try progressServices()["QuestManager"] else {
            throw ProbeError.unavailable("questServiceNotReady")
        }
        let dictionary = try memory.uint(at: objectField(manager, "m_chainQuestIdToPrevious"))
        guard dictionary != 0 else { return nil }
        let version = try integer(dictionary, "_version")
        var ids = Set<Int>()
        for entry in try dictionaryEntries(dictionary) {
            guard entry.keyType == 8, entry.valueType == 8 else {
                throw ProbeError.invalid("Unexpected quest chain dictionary types")
            }
            let current = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.keyAddress, width: 4))))
            let previous = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.valueAddress, width: 4))))
            guard current > 0, previous > 0 else { throw ProbeError.invalid("Invalid quest chain link") }
            ids.insert(current)
            ids.insert(previous)
        }
        guard try progressServices()["QuestManager"] == manager,
              try memory.uint(at: objectField(manager, "m_chainQuestIdToPrevious")) == dictionary,
              try integer(dictionary, "_version") == version else {
            throw ProbeError.unavailable("questChainsChangedDuringRead")
        }
        // An empty map may precede InitializeQuestAssets; do not claim that
        // every assigned quest is non-chain while it is still loading.
        return ids.isEmpty ? nil : ids
    }

    private struct DbfRecordSnapshot {
        let table: UInt64
        let dictionary: UInt64
        let version: Int
        let records: [Int: UInt64]
    }

    private func dbfRecords(_ tableName: String, ids: Set<Int>) throws -> DbfRecordSnapshot {
        guard !ids.isEmpty else { return DbfRecordSnapshot(table: 0, dictionary: 0, version: 0, records: [:]) }
        let table = try staticObject("GameDbf", tableName)
        guard table != 0 else { throw ProbeError.unavailable("questDbfNotInitialized: " + tableName) }
        let dictionary = try memory.uint(at: objectField(table, "m_recordsById"))
        guard dictionary != 0 else { throw ProbeError.unavailable("questDbfNotInitialized: " + tableName) }
        let version = try integer(dictionary, "_version")
        var result: [Int: UInt64] = [:]
        for entry in try dictionaryEntries(dictionary) {
            guard entry.keyType == 8, [18, 21, 28].contains(entry.valueType) else {
                throw ProbeError.invalid("Unexpected quest DBF dictionary types")
            }
            let id = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.keyAddress, width: 4))))
            guard ids.contains(id) else { continue }
            let record = try memory.uint(at: entry.valueAddress)
            guard record != 0 else { throw ProbeError.unavailable("questDbfRecordUnavailable") }
            guard result[id] == nil, try integer(record, "m_ID") == id else {
                throw ProbeError.invalid("Invalid quest DBF record ID")
            }
            result[id] = record
        }
        return DbfRecordSnapshot(table: table, dictionary: dictionary, version: version, records: result)
    }

    private func verifyDbfSnapshot(_ snapshot: DbfRecordSnapshot, tableName: String) throws {
        guard snapshot.table != 0 else { return }
        guard try staticObject("GameDbf", tableName) == snapshot.table,
              try memory.uint(at: objectField(snapshot.table, "m_recordsById")) == snapshot.dictionary,
              try integer(snapshot.dictionary, "_version") == snapshot.version else {
            throw ProbeError.unavailable("questDbfChangedDuringRead")
        }
    }

    private func currentLocaleIdentity() throws -> (object: UInt64, value: Int) {
        let object = try staticObject("Localization", "s_instance")
        guard object != 0 else { throw ProbeError.unavailable("questLocaleUnavailable") }
        let value = try integer(object, "m_locale")
        guard value >= 0 else { throw ProbeError.invalid("Invalid quest locale") }
        return (object, value)
    }

    private func localizedDbfString(_ object: UInt64, localeIndex: inout Int?) throws -> String {
        if object == 0 { return "" }
        let stripped = try memory.uint(at: objectField(object, "m_stripped"), width: 1)
        guard stripped <= 1 else { throw ProbeError.invalid("Invalid localized DBF flag") }
        if stripped == 1 {
            // DbfLocValue.StripUnusedLocales stores the actual locale's value
            // here and releases m_locValues. This is its GetString fast path.
            return try managedString(memory.uint(at: objectField(object, "m_currentLocaleValue")))
        }
        if localeIndex == nil { localeIndex = try currentDbfLocaleIndex() }
        guard let index = localeIndex, index >= 0 else { throw ProbeError.unavailable("questLocaleUnavailable") }
        let values = try memory.uint(at: objectField(object, "m_locValues"))
        guard values != 0 else { throw ProbeError.unavailable("questLocalizedValuesUnavailable") }
        let count = try memory.uint(at: values + 24)
        guard count <= 64 else { throw ProbeError.invalid("Invalid localized DBF array") }
        guard UInt64(index) < count else { throw ProbeError.unavailable("questLocaleNotLoaded") }
        return try managedString(memory.uint(at: values + 32 + UInt64(index) * 8))
    }

    private func currentDbfLocaleIndex() throws -> Int {
        let selected = try currentLocaleIdentity().value
        let map = try staticObject("Localization", "LOCALE_MAP")
        guard map != 0 else { throw ProbeError.unavailable("questLocaleMapUnavailable") }
        var actual: Int?
        for entry in try dictionaryEntries(map) {
            guard [8, 17].contains(entry.keyType), [8, 17].contains(entry.valueType) else {
                throw ProbeError.invalid("Unexpected locale map types")
            }
            let key = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.keyAddress, width: 4))))
            if key == selected {
                actual = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.valueAddress, width: 4))))
            }
        }
        guard let actual else { throw ProbeError.unavailable("questLocaleNotMapped") }
        let locales = try staticObject("Localization", "SupportedLocales")
        guard locales != 0 else { throw ProbeError.unavailable("questSupportedLocalesUnavailable") }
        let count = try integer(locales, "_size")
        let items = try memory.uint(at: objectField(locales, "_items"))
        guard items != 0, count >= 0, count <= 64 else { throw ProbeError.invalid("Invalid supported locale list") }
        let length = try memory.uint(at: items + 24)
        guard UInt64(count) <= length, length <= 64 else { throw ProbeError.invalid("Invalid supported locale array") }
        for index in 0..<count {
            let locale = Int(Int32(bitPattern: UInt32(try memory.uint(at: items + 32 + UInt64(index) * 4, width: 4))))
            if locale == actual { return index }
        }
        throw ProbeError.unavailable("questLocaleNotSupported")
    }

    public func readAchievements() throws -> [[String: Int]] {
        guard let manager = try progressServices()["AchievementManager"] else { throw ProbeError.unavailable("achievementServiceNotReady") }
        let state = try memory.uint(at: objectField(manager, "m_playerState"))
        let map = try memory.uint(at: objectField(state, "m_playerState"))
        let generation = try integer(map, "generation")
        let records = try mapValues(map).map { try progressRecord($0, idField: "AchievementId") }
        guard try integer(map, "generation") == generation else { throw ProbeError.unavailable("mapChangedDuringRead") }
        return records
    }

    public func readInGameAchievements() throws -> [[String: Int]] {
        guard let manager = try progressServices()["AchievementManager"] else { throw ProbeError.unavailable("achievementServiceNotReady") }
        let dictionary = try memory.uint(at: objectField(manager, "m_achievementInGameProgress"))
        let version = try integer(dictionary, "_version")
        let records = try dictionaryEntries(dictionary).map { entry in
            guard entry.keyType == 8, entry.valueType == 8 else { throw ProbeError.invalid("Unexpected in-game counter types") }
            let id = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.keyAddress, width: 4))))
            let progress = Int(Int32(bitPattern: UInt32(try memory.uint(at: entry.valueAddress, width: 4))))
            guard id > 0, progress >= 0 else { throw ProbeError.invalid("Invalid in-game progress") }
            return ["id": id, "progress": progress]
        }
        guard try integer(dictionary, "_version") == version else { throw ProbeError.unavailable("dictionaryChangedDuringRead") }
        return records
    }
    private func managedString(_ address: UInt64) throws -> String {
        if address == 0 { return "" }
        let length = try memory.uint(at: address + 16, width: 4)
        guard length <= 16384 else { throw ProbeError.invalid("Invalid localized string length") }
        if length == 0 { return "" }
        guard let result = String(data: try memory.data(at: address + 20, count: Int(length) * 2), encoding: .utf16LittleEndian) else {
            throw ProbeError.invalid("Invalid localized string")
        }
        return result
    }

    public func readAchievementDefinitions() throws -> [AccountAchievementDefinition] {
        guard let manager = try progressServices()["AchievementManager"] else { throw ProbeError.unavailable("achievementServiceNotReady") }
        let lazy = try memory.uint(at: objectField(manager, "m_achievementDataModelMap"))
        let dictionary = try memory.uint(at: objectField(lazy, "_value"))
        if dictionary == 0 { return [] } // Do not invoke the game's lazy factory.
        return try dictionaryValues(dictionary).map { object in
            AccountAchievementDefinition(
                id: try integer(object, "m_ID"),
                name: try managedString(memory.uint(at: objectField(object, "m_Name"))),
                description: try managedString(memory.uint(at: objectField(object, "m_Description"))),
                quota: try integer(object, "m_Quota"),
                nextId: try integer(object, "m_NextTierID"))
        }
    }

}
