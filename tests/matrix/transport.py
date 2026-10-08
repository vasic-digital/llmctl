"""Transport-level probes that no per-request client adapter can express (stdlib only):
slow-client deadline (EP-024), per-source connection cap with a second source (EP-026),
non-loopback refusal of the engine port (EP-071), and small TLS helpers shared with
negative_tls.py. Each function returns (ok: bool, detail: dict); detail is JSON-able and
contains no secrets.
"""
import errno
import socket
import ssl
import time
import urllib.request


def ctx_for(cacert):
    return ssl.create_default_context(cafile=cacert)


def https_get(host, port, cacert, path="/readyz", source=None, timeout=5.0, server_hostname="localhost"):
    """Plain HTTPS GET with Connection: close; returns (status or None, error or None)."""
    try:
        raw = socket.create_connection((host, port), timeout=timeout, source_address=(source, 0) if source else None)
        with ctx_for(cacert).wrap_socket(raw, server_hostname=server_hostname) as s:
            s.settimeout(timeout)
            s.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % path).encode())
            data = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
        line = data.split(b"\r\n", 1)[0].decode("latin-1")
        return int(line.split()[1]), None
    except Exception as e:  # noqa: BLE001 - detail is reported, never swallowed
        return None, "%s: %s" % (type(e).__name__, e)


def slow_client(host, port, cacert, max_s, server_hostname="localhost"):
    """Drip-feed request headers; the server must close the connection within max_s while
    an ordinary request on a second connection keeps being answered."""
    detail = {"max_s": max_s}
    t0 = time.time()
    try:
        raw = socket.create_connection((host, port), timeout=5)
        s = ctx_for(cacert).wrap_socket(raw, server_hostname=server_hostname)
    except Exception as e:  # noqa: BLE001
        return False, {"error": "could not open the slow connection: %s" % e}
    s.settimeout(0.3)
    s.sendall(b"POST /v1/systemone HTTP/1.1\r\nHost: localhost\r\nX-Slow: ")
    closed_after = None
    others_ok = None
    sent = 0
    while time.time() - t0 < max_s:
        try:
            s.sendall(b"a")
            sent += 1
        except OSError:
            closed_after = time.time() - t0
            break
        try:
            if s.recv(1) == b"":
                closed_after = time.time() - t0
                break
        except socket.timeout:
            pass
        except OSError:
            closed_after = time.time() - t0
            break
        if others_ok is None and time.time() - t0 > 0.8:
            st, _ = https_get(host, port, cacert, "/readyz", server_hostname=server_hostname)
            others_ok = st is not None and st < 500 or st == 503
        time.sleep(0.4)
    try:
        s.close()
    except OSError:
        pass
    if others_ok is None:
        st, _ = https_get(host, port, cacert, "/readyz", server_hostname=server_hostname)
        others_ok = st is not None
    detail.update({"bytes_dripped": sent, "closed_after_s": None if closed_after is None else round(closed_after, 2),
                   "other_client_answered": bool(others_ok)})
    return closed_after is not None and bool(others_ok), detail


def conn_cap(host, port, cacert, cap, second_source="127.0.0.2", server_hostname="localhost"):
    """Open cap+6 idle TCP connections from one source; at least one must be shed (reset or
    closed by the server before TLS) while a second source still completes a TLS request."""
    held, shed = [], 0
    detail = {"cap": cap}
    try:
        for _ in range(cap + 6):
            try:
                held.append(socket.create_connection((host, port), timeout=3))
            except OSError:
                shed += 1
        time.sleep(0.6)
        for c in held:
            c.settimeout(0.2)
            try:
                if c.recv(1) == b"":
                    shed += 1
            except socket.timeout:
                pass
            except OSError as e:
                if e.errno in (errno.ECONNRESET, errno.EPIPE):
                    shed += 1
        st, er = https_get(host, port, cacert, "/readyz", source=second_source, server_hostname=server_hostname)
    finally:
        for c in held:
            try:
                c.close()
            except OSError:
                pass
    detail.update({"opened": cap + 6, "shed": shed, "second_source": second_source,
                   "second_source_status": st, "second_source_error": er})
    return shed >= 1 and st is not None, detail


def nonloopback_ip():
    """First non-loopback IPv4 address of this host, or None."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))  # TEST-NET-1: no packet is sent for a UDP connect
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            if not info[4][0].startswith("127."):
                return info[4][0]
    except OSError:
        pass
    return None


def engine_refused(host_ip, engine_port):
    """The loopback engine port must answer on 127.0.0.1 (control) and refuse on the host's other address."""
    detail = {"engine_port": engine_port, "host_ip": host_ip}
    try:
        socket.create_connection(("127.0.0.1", engine_port), timeout=3).close()
        detail["loopback_control"] = "connected"
    except OSError as e:
        detail["loopback_control"] = "failed: %s" % e
        return False, detail  # blind: cannot tell refusal from a dead port
    try:
        socket.create_connection((host_ip, engine_port), timeout=3).close()
        detail["non_loopback"] = "CONNECTED (engine exposed)"
        return False, detail
    except OSError as e:
        detail["non_loopback"] = "refused: %s" % e
        return e.errno == errno.ECONNREFUSED, detail


def plain_http_to_tls(host, port):
    """Raw plain-HTTP request to the TLS port: must be reset/closed without any HTTP answer."""
    detail = {}
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.sendall(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
        s.settimeout(5)
        data = s.recv(4096)
        s.close()
    except (ConnectionResetError, BrokenPipeError) as e:
        detail["outcome"] = "reset: %s" % type(e).__name__
        return True, detail
    except OSError as e:
        detail["outcome"] = "error: %s" % e
        return False, detail
    detail["outcome"] = "peer answered %d bytes" % len(data) if data else "closed without a byte"
    detail["answer_starts_with_http"] = data.startswith(b"HTTP/")
    return not data.startswith(b"HTTP/"), detail
