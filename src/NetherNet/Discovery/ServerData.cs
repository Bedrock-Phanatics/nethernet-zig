using System.Text;

namespace NetherNet.Discovery;

public enum GameType
{
    Survival = 0,
    Creative = 1,
    Adventure = 2
}

public enum TransportLayer
{
    RakNet = 0,
    NetherNet = 2,
    Default = 4
}

public sealed record ServerData
{
    public const byte CurrentVersion = 6;
    public string ServerName { get; init; } = string.Empty;
    public string LevelName { get; init; } = string.Empty;
    public GameType GameType { get; init; }
    public int PlayerCount { get; init; }
    public int MaxPlayerCount { get; init; }
    public bool EditorWorld { get; init; }
    public bool Hardcore { get; init; }
    public bool AcceptsOnlineAuth { get; init; }
    public bool AcceptsSelfSignedAuth { get; init; }
    public string Nonce { get; init; } = string.Empty;
    public TransportLayer TransportLayer { get; init; } = TransportLayer.NetherNet;
    public int ConnectionType { get; init; } = 4;

    public byte[] Marshal()
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream, Encoding.UTF8, true);
        writer.Write(CurrentVersion);
        WriteString(writer, ServerName);
        WriteString(writer, LevelName);
        WriteVarInt(writer, (int)GameType);
        writer.Write(PlayerCount);
        writer.Write(MaxPlayerCount);
        writer.Write(EditorWorld);
        writer.Write(Hardcore);
        writer.Write(AcceptsOnlineAuth);
        writer.Write(AcceptsSelfSignedAuth);
        WriteString(writer, Nonce);
        WriteVarInt(writer, (int)TransportLayer);
        WriteVarInt(writer, ConnectionType);
        return stream.ToArray();
    }

    public static ServerData Unmarshal(ReadOnlySpan<byte> data)
    {
        using var stream = new MemoryStream(data.ToArray(), false);
        using var reader = new BinaryReader(stream, Encoding.UTF8, false);
        var version = reader.ReadByte();
        if (version != CurrentVersion)
        {
            throw new InvalidDataException($"Server data version mismatch: got {version}, want {CurrentVersion}.");
        }
        var result = new ServerData
        {
            ServerName = ReadString(reader),
            LevelName = ReadString(reader),
            GameType = (GameType)ReadVarInt(reader),
            PlayerCount = reader.ReadInt32(),
            MaxPlayerCount = reader.ReadInt32(),
            EditorWorld = reader.ReadBoolean(),
            Hardcore = reader.ReadBoolean(),
            AcceptsOnlineAuth = reader.ReadBoolean(),
            AcceptsSelfSignedAuth = reader.ReadBoolean(),
            Nonce = ReadString(reader),
            TransportLayer = (TransportLayer)ReadVarInt(reader),
            ConnectionType = ReadVarInt(reader)
        };
        if (stream.Position != stream.Length)
        {
            throw new InvalidDataException($"Server data has {stream.Length - stream.Position} unread bytes.");
        }
        return result;
    }

    private static void WriteString(BinaryWriter writer, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        WriteVarUInt(writer, checked((uint)bytes.Length));
        writer.Write(bytes);
    }

    private static string ReadString(BinaryReader reader)
    {
        var length = ReadVarUInt(reader);
        if (length > reader.BaseStream.Length - reader.BaseStream.Position)
        {
            throw new InvalidDataException($"String length {length} exceeds remaining bytes.");
        }
        var bytes = new byte[checked((int)length)];
        reader.ReadExactly(bytes);
        return Encoding.UTF8.GetString(bytes);
    }

    private static void WriteVarInt(BinaryWriter writer, int value) => WriteVarUInt(writer, unchecked((uint)((value << 1) ^ (value >> 31))));
    private static int ReadVarInt(BinaryReader reader)
    {
        var value = ReadVarUInt(reader);
        return unchecked((int)(value >> 1) ^ -((int)value & 1));
    }

    private static void WriteVarUInt(BinaryWriter writer, uint value)
    {
        while (value >= 0x80)
        {
            writer.Write((byte)(value | 0x80));
            value >>= 7;
        }
        writer.Write((byte)value);
    }

    private static uint ReadVarUInt(BinaryReader reader)
    {
        uint value = 0;
        for (var shift = 0; shift < 35; shift += 7)
        {
            var current = reader.ReadByte();
            value |= (uint)(current & 0x7f) << shift;
            if ((current & 0x80) == 0)
            {
                return value;
            }
        }
        throw new InvalidDataException("VarUInt32 did not terminate after 5 bytes.");
    }
}
