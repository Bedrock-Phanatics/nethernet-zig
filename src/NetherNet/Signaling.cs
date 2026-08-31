namespace NetherNet;

public interface INotifier
{
    bool NotifySignal(Signal signal);
}

public interface ISignaling
{
    ValueTask SignalAsync(
        Signal signal,
        CancellationToken cancellationToken = default);

    IDisposable Notify(INotifier notifier);

    CancellationToken Closed { get; }

    ValueTask<Credentials?> GetCredentialsAsync(
        CancellationToken cancellationToken = default);

    string NetworkId { get; }

    void SetPongData(ReadOnlySpan<byte> data);
}

public interface IDisablesTrickleIce
{
    bool DisableTrickleIce { get; }
}
