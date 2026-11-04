import Foundation
import MCP
import XCTest
@testable import BridgeMCP

final class ModernResponsesTests: XCTestCase {
  private static func server() async -> Server {
    let server = Server(name: "test", version: "1")
    await MCPFileTransferResource.register(on: server)
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: []) }
    return server
  }

  private func registry() -> MCPSessionRegistry {
    MCPSessionRegistry(
      boundPort: 8080,
      serverFactory: { _ in await ModernResponsesTests.server() },
      statelessServerFactory: { await ModernResponsesTests.server() }
    )
  }

  private func request(_ method: String, uri: String? = nil) throws -> HTTPRequest {
    var params: [String: Any] = ["_meta": [
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": [:],
    ]]
    var headers = [
      "Host": "localhost:8080", "Accept": "application/json, text/event-stream",
      "Content-Type": "application/json", "Mcp-Protocol-Version": "2026-07-28",
      "Mcp-Method": method,
    ]
    if let uri { params["uri"] = uri; headers["Mcp-Name"] = uri }
    let body = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 7, "method": method, "params": params,
    ])
    return HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
  }

  private func json(_ response: HTTPResponse) throws -> [String: Any] {
    XCTAssertEqual(response.statusCode, 200)
    let body = try XCTUnwrap(response.bodyData)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  func testModernHTTPResponses() async throws {
    let registry = registry()
    for method in ["server/discover", "tools/list", "resources/list", "resources/read"] {
      let uri = method == "resources/read" ? MCPFileTransferResource.uri : nil
      let response = await registry.handle(try request(method, uri: uri))
      let object = try json(response)
      XCTAssertEqual(object["id"] as? Int, 7)
      let result = try XCTUnwrap(object["result"] as? [String: Any])
      XCTAssertEqual(result["resultType"] as? String, "complete", method)
      XCTAssertEqual(result["ttlMs"] as? Int, 0, method)
      XCTAssertEqual(result["cacheScope"] as? String, "private", method)
      if method == "resources/read" {
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["uri"] as? String, uri)
        XCTAssertNotNil(contents.first?["text"] as? String)
      }
    }
    let missing = await registry.handle(try request("resources/read", uri: "ui://missing"))
    let error = try json(missing)
    XCTAssertNotNil(error["error"])
    XCTAssertNil(error["result"])
  }

  func testAdaptationOnlyCachesCompleteCacheableResults() async throws {
    let registry = registry()
    for method in ["tools/list", "prompts/list", "resources/list", "resources/templates/list", "resources/read"] {
      let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": [:]])
      let response = await registry.adaptingModernResponse(.data(body), for: try request(method))
      let result = try XCTUnwrap(try json(response)["result"] as? [String: Any])
      XCTAssertEqual(result["ttlMs"] as? Int, 0, method)
      XCTAssertEqual(result["cacheScope"] as? String, "private", method)
    }
    for (method, resultType) in [("resources/read", "input_required"), ("tools/call", "complete")] {
      let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["resultType": resultType]])
      let response = await registry.adaptingModernResponse(.data(body), for: try request(method))
      let result = try XCTUnwrap(try json(response)["result"] as? [String: Any])
      XCTAssertEqual(result["resultType"] as? String, resultType)
      XCTAssertNil(result["ttlMs"])
      XCTAssertNil(result["cacheScope"])
    }
  }
}
