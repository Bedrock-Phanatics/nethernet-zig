using System.Buffers.Binary;
using System.Security.Cryptography;

namespace NetherNet.Internal;

internal static class RandomId
{
    internal static ulong Create() =>
        BinaryPrimitives.ReadUInt64LittleEndian(
            RandomNumberGenerator.GetBytes(sizeof(ulong)));
}
