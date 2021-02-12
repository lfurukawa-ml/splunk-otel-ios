import Foundation
import OpenTelemetryApi

let serverTimingPattern = #"traceparent;desc=\"00-([0-9a-f]{32})-([0-9a-f]{16})-01\""#

public func addLinkToSpan(span: Span, valStr: String) {
    // FIXME this is the worst regex interface I have ever seen in two+ decades of professional programming
    let regex = try! NSRegularExpression(pattern: serverTimingPattern)
    let result = regex.matches(in: valStr, range: NSRange(location: 0, length: valStr.utf16.count))
    // per standard regex logic, number of matched segments is 3 (whole match plus two () captures)
    if result.count != 1 || result[0].numberOfRanges != 3 {
        return
    }
    let traceId = String(valStr[Range(result[0].range(at: 1), in: valStr)!])
    let spanId = String(valStr[Range(result[0].range(at: 2), in: valStr)!])
    span.setAttribute(key: "link.traceId", value: traceId)
    span.setAttribute(key: "link.spanId", value: spanId)
}

func endHttpSpan(span: Span?, task: URLSessionTask) {
    if span == nil {
        return
    }
    let hr: HTTPURLResponse? = task.response as? HTTPURLResponse
    if hr != nil {
        span!.setAttribute(key: "http.status_code", value: hr!.statusCode)
        // Blerg, looks like an iteration here since it is case sensitive and the case insensitive search assumes single value
        for (key, val) in hr!.allHeaderFields {
            let keyStr = key as? String
            if keyStr != nil {
                if keyStr?.caseInsensitiveCompare("server-timing") == .orderedSame {
                    let valStr = val as? String
                    if valStr != nil {
                        if valStr!.starts(with: "traceparent") {
                            addLinkToSpan(span: span!, valStr: valStr!)
                        }
                    }
                }
            }
        }
    }
    if task.error != nil {
        span!.setAttribute(key: "error", value: true)
        span!.setAttribute(key: "error.message", value: task.error!.localizedDescription)
        // FIXME what else can be divined?
    }
    span!.setAttribute(key: "http.response_content_length_uncompressed", value: Int(task.countOfBytesReceived))
    // FIXME experiment with countOfBytesSent for upload/POST tasks
    span!.end()
}

func startHttpSpan(request: URLRequest?) -> Span? {
    if request == nil || request?.url == nil {
        return nil
    }
    let url = request!.url!
    let method = request!.httpMethod ?? "GET"
    // FIXME even without the hardcode, this is a terrible way to supress spans from the zipkin exporter
    if url.absoluteString.contains("auth=") {
        return nil
    }
    // FIXME constants for this stuff
    let tracer = OpenTelemetry.instance.tracerProvider.get(instrumentationName: "ios", instrumentationVersion: "0.0.1")
    let span = tracer.spanBuilder(spanName: "HTTP "+method).startSpan()
    // FIXME http.method, try for http.response_content_length and http.request_content_length
    span.setAttribute(key: "http.url", value: url.absoluteString)
    span.setAttribute(key: "http.method", value: method)
    return span
}
class SessionTaskObserver: NSObject {
    // FIXME multithreading here and with span api itself
    let task2span = NSMapTable<URLSessionTask, AnyObject>.weakToStrongObjects()

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let task = object as? URLSessionTask
        if task == nil {
            return
        }
        let key = task!
        var span = task2span.object(forKey: key) as? Span
        if span == nil {
            span = startHttpSpan(request: task!.originalRequest)
            if span != nil {
                task2span.setObject(span, forKey: key)
            }
        }
        if task!.state == .completed {
            endHttpSpan(span: span,
                        task: task!)
        }
    }
}
let TheSessionTaskObserver = SessionTaskObserver() // stateless

func wireUpTaskObserver(task: URLSessionTask) {
    task.addObserver(TheSessionTaskObserver, forKeyPath: "state", options: .new, context: nil)
}

extension URLSession {
    // FIXME 6 downloadTask
    // FIXME 5 uploadTask

    // FIXME none of these actually check for http(s)-ness
    @objc open func swizzled_dataTask(with url: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let answer = swizzled_dataTask(with: url, completionHandler: completionHandler)
        wireUpTaskObserver(task: answer)
        return answer
       }

    @objc open func swizzled_dataTask(with url: URL) -> URLSessionDataTask {
        let answer = swizzled_dataTask(with: url)
        wireUpTaskObserver(task: answer)
        return answer
       }

    // rename objc view of func to allow "overloading"
    @objc(swizzledDataTaskWithRequest: completionHandler:) open func swizzled_dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let answer = swizzled_dataTask(with: request, completionHandler: completionHandler)
        wireUpTaskObserver(task: answer)
        return answer
       }

    @objc(swizzledDataTaskWithRequest:) open func swizzled_dataTask(with request: URLRequest) -> URLSessionDataTask {
        let answer = swizzled_dataTask(with: request)
        wireUpTaskObserver(task: answer)
        return answer
       }
}

// FIXME use setImplementation and capture, rather than exchangeImpl
func swizzle(clazz: AnyClass, orig: Selector, swizzled: Selector) {
    let origM = class_getInstanceMethod(clazz, orig)
    let swizM = class_getInstanceMethod(clazz, swizzled)
    if origM != nil && swizM != nil {
        method_exchangeImplementations(origM!, swizM!)
    } else {
        // FIXME logging
        print("warning: could not swizzle "+NSStringFromSelector(orig))
    }
}
func initalizeNetworkInstrumentation() {
    // FIXME experiment with emphemeral and results of the function background(withIdentifier) -> same method impls?
    let urlsession = URLSession.self

    // This syntax is obnoxious to differentiate with:request from with:url
    swizzle(clazz: urlsession,
            orig: #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask),
            swizzled: #selector(URLSession.swizzled_dataTask(with:completionHandler:) as (URLSession) -> (URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask))

    swizzle(clazz: urlsession,
            orig: #selector(URLSession.dataTask(with:) as (URLSession) -> (URL) -> URLSessionDataTask),
            swizzled: #selector(URLSession.swizzled_dataTask(with:) as (URLSession) -> (URL) -> URLSessionDataTask))

    // @objc(overrrideName) requires a runtime lookup rather than a build-time lookup (seems like a bug in the compiler)
    swizzle(clazz: urlsession,
            orig: #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask),
            swizzled: NSSelectorFromString("swizzledDataTaskWithRequest:completionHandler:"))

    swizzle(clazz: urlsession,
            orig: #selector(URLSession.dataTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDataTask),
            swizzled: NSSelectorFromString("swizzledDataTaskWithRequest:"))

}
