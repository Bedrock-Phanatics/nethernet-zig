using System.Net;

namespace NetherNet;

public sealed class NetherNetAddress : EndPoint
{
    public NetherNetAddress(
        string networkId,
        ulong connectionId,
        IPEndPoint? remoteEndPoint = null)
    {
        NetworkId = networkId;
        ConnectionId = connectionId;
        RemoteEndPoint = remoteEndPoint;
    }

    public string NetworkId { get; }
    public ulong ConnectionId { get; }
    public IPEndPoint? RemoteEndPoint { get; }
    public override AddressFamily AddressFamily =>
        RemoteEndPoint?.AddressFamily ?? AddressFamily.Unspecified;

    public override string ToString()
    {
        var connection = ConnectionId == 0 ? string.Empty : $" ({ConnectionId})";
        var endpoint = RemoteEndPoint is null ? string.Empty : $" ({RemoteEndPoint})";
        return $"{NetworkId}{connection}{endpoint}";
    }
}
