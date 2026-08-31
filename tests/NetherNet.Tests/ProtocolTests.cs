using System.Security.Cryptography;
using System.Text.Json;
using NetherNet.Discovery;

namespace NetherNet.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void SignalRoundTripsWithSpacesAndNewlines()
    {
        var signal = new Signal { Type = SignalTypes.Offer, ConnectionId = 42, Data = "v=0\r\na=candidate: hello world" };
        Assert.Equal(signal, Signal.Parse(signal.ToString()));
    }

    [Fact]
    public void DiscoveryPacketIdsMatchVanilla()
    {
        Assert.Equal((ushort)0, new RequestPacket().Id);
        Assert.Equal((ushort)1, new ResponsePacket().Id);
        Assert.Equal((ushort)2, new MessagePacket().Id);
    }

    [Fact]
    public void DiscoveryPacketsRoundTrip()
    {
        const ulong sender = 0x1020304050607080;
        var packets = new IPacket[]
        {
            new RequestPacket(),
            new ResponsePacket { ApplicationData = [0, 1, 2, 0xfe, 0xff] },
            new MessagePacket { RecipientId = 9, Data = "CONNECTREQUEST 7 v=0\r\n" }
        };
        foreach (var packet in packets)
        {
            var decoded = PacketCodec.Unmarshal(PacketCodec.Marshal(packet, sender));
            Assert.Equal(sender, decoded.SenderId);
            Assert.Equal(packet.Id, decoded.Packet.Id);
            if (packet is ResponsePacket response)
            {
                Assert.Equal(response.ApplicationData, Assert.IsType<ResponsePacket>(decoded.Packet).ApplicationData);
            }

            if (packet is MessagePacket message)
            {
                var actual = Assert.IsType<MessagePacket>(decoded.Packet);
                Assert.Equal(message.RecipientId, actual.RecipientId);
                Assert.Equal(message.Data, actual.Data);
            }
        }
    }

    [Fact]
    public void DiscoveryPacketRejectsTampering()
    {
        var encoded = PacketCodec.Marshal(new RequestPacket(), 1);
        encoded[^1] ^= 1;
        Assert.ThrowsAny<CryptographicException>(() => PacketCodec.Unmarshal(encoded));
    }

    [Fact]
    public void ServerDataMatchesUpstreamByteVector()
    {
        var data = new ServerData
        {
            ServerName = "server",
            LevelName = "world",
            GameType = GameType.Adventure,
            PlayerCount = 1,
            MaxPlayerCount = 8,
            Hardcore = true,
            AcceptsOnlineAuth = true,
            AcceptsSelfSignedAuth = true,
            Nonce = "nonce",
            TransportLayer = TransportLayer.NetherNet,
            ConnectionType = 4
        };
        byte[] expected = [
            0x06, 0x06, (byte)'s', (byte)'e', (byte)'r', (byte)'v', (byte)'e', (byte)'r',
            0x05, (byte)'w', (byte)'o', (byte)'r', (byte)'l', (byte)'d', 0x04,
            0x01, 0, 0, 0, 0x08, 0, 0, 0, 0, 1, 1, 1,
            0x05, (byte)'n', (byte)'o', (byte)'n', (byte)'c', (byte)'e', 0x04, 0x08
        ];
        Assert.Equal(expected, data.Marshal());
        Assert.Equal(data, ServerData.Unmarshal(expected));
    }

    [Fact]
    public void ServerIdentitySelfSignatureAndFingerprintAssertionVerify()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP384);
        var identity = Identity.GenerateServer(key, "self");
        using var publicKey = Identity.ClaimPublicKey(identity.Token, true);
        var tokenParts = identity.Token.Split('.');
        using var tokenHeader = JsonDocument.Parse(Base64Url.Decode(tokenParts[0]));
        Assert.Equal("ES384", tokenHeader.RootElement.GetProperty("alg").GetString());
        Assert.True(tokenHeader.RootElement.TryGetProperty("x5u", out _));
        Assert.False(tokenHeader.RootElement.TryGetProperty("typ", out _));
        var fingerprints = new[] { new DtlsFingerprint("sha-256", "00:11:22:33:44:55") };
        var assertion = identity.CreateAssertion(fingerprints);
        var assertionParts = assertion.Assertion.Fingerprints.Split('.');
        Assert.Equal(string.Empty, assertionParts[1]);
        using var assertionHeader = JsonDocument.Parse(Base64Url.Decode(assertionParts[0]));
        Assert.Equal("ES384", assertionHeader.RootElement.GetProperty("alg").GetString());
        Assert.False(assertionHeader.RootElement.TryGetProperty("typ", out _));
        assertion.Verify(fingerprints, publicKey);
        Assert.Throws<CryptographicException>(() => assertion.Verify([new DtlsFingerprint("sha-256", "ff")], publicKey));
    }
}
