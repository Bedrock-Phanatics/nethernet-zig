using Microsoft.AspNetCore.Routing;

namespace NetherNet.Endpoint;

public static class EndpointRouteBuilderExtensions
{
    public static EndpointHandler MapNetherNet(
        this IEndpointRouteBuilder endpoints,
        EndpointHandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(endpoints);

        var handler = new EndpointHandler(options);
        handler.MapEndpoints(endpoints);
        return handler;
    }
}
