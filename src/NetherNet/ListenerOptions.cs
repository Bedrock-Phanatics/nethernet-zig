namespace NetherNet;

public sealed record ListenerOptions
{
    public bool DisableTrickleIce { get; init; }
    public bool AllowAnonymous { get; init; }
    public Func<CancellationToken, ValueTask<Identity>>? IssueServerIdentity { get; init; }
    public Func<string, CancellationToken, ValueTask<ECDsa?>>? VerifyClientToken { get; init; }
    public TimeSpan NegotiationTimeout { get; init; } = TimeSpan.FromSeconds(15);
    public TimeSpan ConnectionTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public int MaximumConcurrentNegotiations { get; init; } = 64;
    public int MaximumPendingAccepts { get; init; } = 64;
    public int MaximumQueuedPacketsPerChannel { get; init; } = 256;
    public int MaximumReconstructedMessageSize { get; init; } = 16 * 1024 * 1024;
}
