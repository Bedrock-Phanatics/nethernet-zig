using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace NetherNet.Discovery;

public interface IPacket
{
    ushort Id { get; }
    void Read(BinaryReader reader);
    void Write(BinaryWriter writer);
}

public sealed class RequestPacket : IPacket
{
    public ushort Id => PacketCodec.RequestPacketId;
    public void Read(BinaryReader reader)
    {
        ArgumentNullException.ThrowIfNull(reader);
    }

    public void Write(BinaryWriter writer)
    {
        ArgumentNullException.ThrowIfNull(writer);
    }
}

public sealed class ResponsePacket : IPacket
{
    public ushort Id => PacketCodec.ResponsePacketId;
    public byte[] ApplicationData { get; set; } = [];

    public void Read(BinaryReader reader)
    {
        ArgumentNullException.ThrowIfNull(reader);
        var encoded = PacketCodec.ReadBytes32(reader);
        if ((encoded.Length & 1) != 0)
        {
            throw new InvalidDataException("Application data is not valid hexadecimal.");
        }

        try
        {
            ApplicationData = Convert.FromHexString(Encoding.ASCII.GetString(encoded));
        }
        catch (FormatException exception)
        {
            throw new InvalidDataException(
                "Application data is not valid hexadecimal.",
                exception);
        }
    }

    public void Write(BinaryWriter writer)
    {
        ArgumentNullException.ThrowIfNull(writer);
        PacketCodec.WriteBytes32(
            writer,
            Encoding.ASCII.GetBytes(Convert.ToHexString(ApplicationData).ToLowerInvariant()));
    }
}

public sealed class MessagePacket : IPacket
{
    public ushort Id => PacketCodec.MessagePacketId;
    public ulong RecipientId { get; set; }
    public string Data { get; set; } = string.Empty;

    public void Read(BinaryReader reader)
    {
        ArgumentNullException.ThrowIfNull(reader);
        RecipientId = reader.ReadUInt64();
        var data = PacketCodec.ReadBytes32(reader);
        var remaining = checked((int)(reader.BaseStream.Length - reader.BaseStream.Position));
        if (remaining > 0)
        {
            var full = new byte[data.Length + remaining];
            data.CopyTo(full, 0);
            reader.ReadExactly(full.AsSpan(data.Length));
            data = full;
        }
        Data = Encoding.UTF8.GetString(data);
    }

    public void Write(BinaryWriter writer)
    {
        ArgumentNullException.ThrowIfNull(writer);
        writer.Write(RecipientId);
        PacketCodec.WriteBytes32(writer, Encoding.UTF8.GetBytes(Data));
    }
}

public static class PacketCodec
{
    public const ushort RequestPacketId = 0;
    public const ushort ResponsePacketId = 1;
    public const ushort MessagePacketId = 2;
    public const int MaximumPayloadLength = ushort.MaxValue;

    private static readonly byte[] Key = SHA256.HashData([0xef, 0xbe, 0xad, 0xde, 0, 0, 0, 0]);

    public static byte[] Marshal(IPacket packet, ulong senderId)
    {
        ArgumentNullException.ThrowIfNull(packet);
        using var body = new MemoryStream();
        using (var writer = new BinaryWriter(body, Encoding.UTF8, true))
        {
            writer.Write(packet.Id);
            writer.Write(senderId);
            writer.Write(new byte[8]);
            packet.Write(writer);
        }
        if (body.Length + 2 > ushort.MaxValue)
        {
            throw new InvalidDataException($"Packet payload exceeds {ushort.MaxValue} bytes.");
        }

        var payload = new byte[checked((int)body.Length + 2)];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, checked((ushort)payload.Length));
        body.GetBuffer().AsSpan(0, checked((int)body.Length)).CopyTo(payload.AsSpan(2));
        var checksum = HMACSHA256.HashData(Key, payload);
        var ciphertext = EncryptEcb(payload);
        var result = new byte[checksum.Length + ciphertext.Length];
        checksum.CopyTo(result, 0);
        ciphertext.CopyTo(result, checksum.Length);
        return result;
    }

    public static (IPacket Packet, ulong SenderId) Unmarshal(ReadOnlySpan<byte> data)
    {
        if (data.Length < 32)
        {
            throw new EndOfStreamException("Discovery packet is shorter than its HMAC.");
        }

        var payload = DecryptEcb(data[32..]);
        var expected = HMACSHA256.HashData(Key, payload);
        if (!CryptographicOperations.FixedTimeEquals(data[..32], expected))
        {
            throw new CryptographicException("Discovery packet checksum mismatch.");
        }

        if (payload.Length < 2)
        {
            throw new EndOfStreamException();
        }

        var declared = BinaryPrimitives.ReadUInt16LittleEndian(payload);
        // Vanilla uses the inclusive length; older implementations wrote an exclusive
        // length. Both are accepted because neither value is needed for framing UDP.
        if (declared != payload.Length && declared != payload.Length - 2)
        {
            throw new InvalidDataException($"Invalid discovery payload length {declared}; actual length is {payload.Length}.");
        }

        using var stream = new MemoryStream(payload, 2, payload.Length - 2, false);
        using var reader = new BinaryReader(stream, Encoding.UTF8, false);
        var id = reader.ReadUInt16();
        var senderId = reader.ReadUInt64();
        reader.ReadExactly(new byte[8]);
        IPacket packet = id switch
        {
            RequestPacketId => new RequestPacket(),
            ResponsePacketId => new ResponsePacket(),
            MessagePacketId => new MessagePacket(),
            _ => throw new InvalidDataException($"Unknown discovery packet ID: {id}.")
        };
        packet.Read(reader);
        if (stream.Position != stream.Length)
        {
            throw new InvalidDataException($"Discovery packet has {stream.Length - stream.Position} unread bytes.");
        }

        return (packet, senderId);
    }

    internal static byte[] ReadBytes32(BinaryReader reader)
    {
        var length = reader.ReadUInt32();
        if (length > MaximumPayloadLength)
        {
            throw new InvalidDataException($"Invalid length: {length}, max {MaximumPayloadLength}.");
        }

        if (reader.BaseStream.CanSeek && length > reader.BaseStream.Length - reader.BaseStream.Position)
        {
            throw new InvalidDataException($"Invalid length: {length}, remaining {reader.BaseStream.Length - reader.BaseStream.Position}.");
        }

        var result = new byte[checked((int)length)];
        reader.ReadExactly(result);
        return result;
    }

    internal static void WriteBytes32(BinaryWriter writer, ReadOnlySpan<byte> data)
    {
        if (data.Length > MaximumPayloadLength)
        {
            throw new InvalidDataException($"Payload exceeds {MaximumPayloadLength} bytes.");
        }

        writer.Write((uint)data.Length);
        writer.Write(data);
    }

    private static byte[] EncryptEcb(ReadOnlySpan<byte> plaintext)
    {
        using var aes = Aes.Create();
        aes.Key = Key;
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.PKCS7;
        return aes.EncryptEcb(plaintext, PaddingMode.PKCS7);
    }

    private static byte[] DecryptEcb(ReadOnlySpan<byte> ciphertext)
    {
        if (ciphertext.IsEmpty || ciphertext.Length % 16 != 0)
        {
            throw new CryptographicException($"Invalid ciphertext length: {ciphertext.Length}.");
        }

        using var aes = Aes.Create();
        aes.Key = Key;
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.PKCS7;
        return aes.DecryptEcb(ciphertext, PaddingMode.PKCS7);
    }
}
