using System.Reflection;
using System.Reflection.Emit;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Text.Json;

// Inspect metadata only: never load or execute game code, and never read account data.
if (args.Length < 1) {
    Console.Error.WriteLine("Usage: Metadata <assembly.dll> [exact-type-name ...] [--il]");
    return 2;
}
try {
    using var stream = File.OpenRead(args[0]);
    using var pe = new PEReader(stream);
    var reader = pe.GetMetadataReader();
    var types = new List<object>();
    foreach (var handle in reader.TypeDefinitions) {
        var type = reader.GetTypeDefinition(handle);
        var name = reader.GetString(type.Name);
        if (args.Length > 1 ? (!args.Skip(1).Contains("*") && !args.Skip(1).Contains(name)) : (!name.Contains("Quest", StringComparison.OrdinalIgnoreCase) &&
            !name.Contains("Achievement", StringComparison.OrdinalIgnoreCase) &&
            !name.Contains("ServiceLocator", StringComparison.Ordinal) && name != "PegasusServices")) continue;
        var fields = type.GetFields().Select(fieldHandle => {
            var field = reader.GetFieldDefinition(fieldHandle);
            return new {
                name = reader.GetString(field.Name),
                isStatic = (field.Attributes & FieldAttributes.Static) != 0,
                type = field.DecodeSignature(new Names(), (object?)null),
                constant = ReadConstant(reader, field.GetDefaultValue())
            };
        }).ToArray();
        var methods = args.Contains("--il") ? type.GetMethods().Select(methodHandle => {
            var method = reader.GetMethodDefinition(methodHandle);
            var body = method.RelativeVirtualAddress == 0 ? null : pe.GetMethodBody(method.RelativeVirtualAddress);
            return new { name = reader.GetString(method.Name), instructions = body == null ? null : ReadIL(reader, body.GetILBytes()!) };
        }).ToArray() : null;
        types.Add(new { name, ns = reader.GetString(type.Namespace), fields, methods });
    }
    Console.WriteLine(JsonSerializer.Serialize(new {
        schemaVersion = 1,
        kind = "metadataOnly",
        moduleId = reader.GetGuid(reader.GetModuleDefinition().Mvid),
        types
    }, new JsonSerializerOptions { WriteIndented = true }));
    return 0;
} catch (Exception error) when (error is IOException or BadImageFormatException or UnauthorizedAccessException) {
    Console.Error.WriteLine("Metadata inspection failed: " + error.Message);
    return 1;
}

static object? ReadConstant(MetadataReader reader, ConstantHandle handle) {
    if (handle.IsNil) return null;
    var constant = reader.GetConstant(handle);
    var blob = reader.GetBlobReader(constant.Value);
    return constant.TypeCode switch {
        ConstantTypeCode.Int32 => blob.ReadInt32(),
        ConstantTypeCode.UInt32 => blob.ReadUInt32(),
        ConstantTypeCode.Int64 => blob.ReadInt64(),
        ConstantTypeCode.UInt64 => blob.ReadUInt64(),
        ConstantTypeCode.Boolean => blob.ReadBoolean(),
        ConstantTypeCode.String => blob.ReadUTF16(blob.Length),
        _ => null
    };
}

static List<string> ReadIL(MetadataReader reader, byte[] bytes) {
    var opcodes = typeof(OpCodes).GetFields(BindingFlags.Public | BindingFlags.Static)
        .Where(f => f.FieldType == typeof(OpCode)).Select(f => (OpCode)f.GetValue(null)!)
        .ToDictionary(op => unchecked((ushort)op.Value));
    var result = new List<string>();
    for (int index = 0; index < bytes.Length;) {
        int offset = index;
        ushort code = bytes[index++];
        if (code == 0xfe) code = (ushort)(0xfe00 | bytes[index++]);
        var opcode = opcodes[code];
        int count = opcode.OperandType switch {
            OperandType.InlineNone => 0,
            OperandType.ShortInlineI or OperandType.ShortInlineVar or OperandType.ShortInlineBrTarget => 1,
            OperandType.InlineVar => 2,
            OperandType.InlineI8 or OperandType.InlineR => 8,
            OperandType.InlineSwitch => 4 + 4 * BitConverter.ToInt32(bytes, index),
            _ => 4
        };
        string operand = count == 0 ? "" : Convert.ToHexString(bytes.AsSpan(index, count));
        if (opcode.OperandType is OperandType.InlineField or OperandType.InlineMethod or OperandType.InlineType or OperandType.InlineTok) {
            var handle = MetadataTokens.EntityHandle(BitConverter.ToInt32(bytes, index));
            operand = handle.Kind switch {
                HandleKind.FieldDefinition => TypeName(reader, reader.GetFieldDefinition((FieldDefinitionHandle)handle).GetDeclaringType()) + "." + reader.GetString(reader.GetFieldDefinition((FieldDefinitionHandle)handle).Name),
                HandleKind.MethodDefinition => TypeName(reader, reader.GetMethodDefinition((MethodDefinitionHandle)handle).GetDeclaringType()) + "." + reader.GetString(reader.GetMethodDefinition((MethodDefinitionHandle)handle).Name),
                HandleKind.MemberReference => TypeName(reader, reader.GetMemberReference((MemberReferenceHandle)handle).Parent) + "." + reader.GetString(reader.GetMemberReference((MemberReferenceHandle)handle).Name),
                HandleKind.TypeDefinition => reader.GetString(reader.GetTypeDefinition((TypeDefinitionHandle)handle).Name),
                HandleKind.TypeReference => reader.GetString(reader.GetTypeReference((TypeReferenceHandle)handle).Name),
                _ => operand
            };
        }
        result.Add($"{offset:x4}: {opcode.Name} {operand}".TrimEnd());
        index += count;
    }
    return result;
}

static string TypeName(MetadataReader reader, EntityHandle handle) => handle.Kind switch {
    HandleKind.TypeDefinition => reader.GetString(reader.GetTypeDefinition((TypeDefinitionHandle)handle).Name),
    HandleKind.TypeReference => reader.GetString(reader.GetTypeReference((TypeReferenceHandle)handle).Name),
    HandleKind.TypeSpecification => reader.GetTypeSpecification((TypeSpecificationHandle)handle).DecodeSignature(new Names(), (object?)null),
    _ => handle.Kind.ToString()
};

sealed class Names : ISignatureTypeProvider<string, object?> {
    public string GetArrayType(string type, ArrayShape shape) => type + "[]";
    public string GetByReferenceType(string type) => type + "&";
    public string GetFunctionPointerType(MethodSignature<string> signature) => "function";
    public string GetGenericInstantiation(string type, System.Collections.Immutable.ImmutableArray<string> args) => type + "<" + string.Join(",", args) + ">";
    public string GetGenericMethodParameter(object? context, int index) => "!!" + index;
    public string GetGenericTypeParameter(object? context, int index) => "!" + index;
    public string GetModifiedType(string modifier, string type, bool required) => type;
    public string GetPinnedType(string type) => type;
    public string GetPointerType(string type) => type + "*";
    public string GetPrimitiveType(PrimitiveTypeCode type) => type.ToString();
    public string GetSZArrayType(string type) => type + "[]";
    public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte kind) => reader.GetString(reader.GetTypeDefinition(handle).Name);
    public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte kind) => reader.GetString(reader.GetTypeReference(handle).Name);
    public string GetTypeFromSpecification(MetadataReader reader, object? context, TypeSpecificationHandle handle, byte kind) => reader.GetTypeSpecification(handle).DecodeSignature(this, context);
}
