namespace NetherNet;

public sealed record DialerOptions
{
    public ulong ConnectionId { get; init; }
    public bool DisableTrickleIce { get; init; }
    public Identity? Identity { get; init; }
    public int MaximumQueuedPacketsPerChannel { get; init; } =
        NetherNetConnection.DefaultMaximumQueuedPacketsPerChannel;
    public int MaximumReconstructedMessageSize { get; init; } =
        NetherNetConnection.DefaultMaximumReconstructedMessageSize;
}
