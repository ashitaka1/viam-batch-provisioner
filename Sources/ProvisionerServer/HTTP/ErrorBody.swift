import Foundation
import Hummingbird
import ProvisionerAPI

typealias ErrorCode = Components.Schemas._Error._ErrorPayload.CodePayload

func errorPayload(_ code: ErrorCode, _ message: String,
                  details: [Components.Schemas.ErrorDetail]? = nil) -> Components.Schemas._Error {
    .init(error: .init(code: code, message: message, details: details))
}

/// A contract `Error` JSON response, for errors raised outside the generated handlers.
func errorResponse(_ status: HTTPResponse.Status, _ code: ErrorCode, _ message: String,
                   headers: HTTPFields = [:]) -> Response {
    let body = (try? JSONEncoder().encode(errorPayload(code, message))) ?? Data()
    var fields = headers
    fields[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(bytes: body)))
}
