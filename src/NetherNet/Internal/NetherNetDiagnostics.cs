using System.Diagnostics;

namespace NetherNet.Internal;

internal static class NetherNetDiagnostics
{
    internal static void Report(Exception exception)
    {
        Trace.TraceError("[NetherNet] {0}", exception);
    }

    internal static void ReportMalformedDatagram(Exception exception)
    {
        Trace.TraceWarning("[NetherNet] Ignored malformed discovery datagram: {0}", exception.Message);
    }
}
