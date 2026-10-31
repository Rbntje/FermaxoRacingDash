"""Local HTTP/WebSocket + EA F1 25 2026 Season Pack UDP bridge.

Uses only Python's standard library. Packet offsets follow EA's version 11.0
2026 Season Pack output structures. Values are published only when parsed from
a correctly sized format-2026 packet.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, hashlib, json, os, socket, struct, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
UDP_PORT = int(os.getenv("F1_UDP_PORT", "20777"))
HTTP_PORT = int(os.getenv("HTTP_PORT", "8080"))
HEADER = 29
CARS = 24
PACKET_LENGTHS = {0: 1325, 1: 926, 2: 1399, 3: 45, 4: 1470, 5: 1233,
                  6: 1448, 7: 1445, 8: 1134, 9: 1062, 10: 1133,
                  11: 1460, 12: 231, 13: 273, 14: 104, 15: 1231, 16: 269}
SESSION_TYPES = {0:"UNKNOWN",1:"P1",2:"P2",3:"P3",4:"SHORT QUALI",5:"QUALI",
                 6:"S1",7:"S2",8:"S3",9:"SHORT SPRINT",10:"SPRINT",11:"RACE",
                 12:"TIME TRIAL"}
FLAG_NAMES = {-1:"--",0:"GREEN",1:"GREEN",2:"BLUE",3:"YELLOW"}

lock = threading.RLock()
clients = set()
state = {"format":2026,"status":"WAITING FOR TELEMETRY","trackId":None,
         "trackName":None,"sessionName":None,"speed":None,"gear":None,"rpm":None,
         "rpmPercent":None,"throttle":None,"brake":None,"currentLapMs":None,
         "lastLapMs":None,"bestLapMs":None,"lap":None,"position":None,
         "sectors":[None,None,None],"tyreTemps":[None,None,None,None],
         "tyreWear":None,"compound":None,"ersPercent":None,"ersKj":None,
         "ersMode":None,"harvestKw":None,"deployKw":None,"fuelKg":None,
         "straightMode":"UNAVAILABLE","overtake":None,"safetyCar":None,
         "safetyDelta":None,"flag":"GREEN","mapReady":False,"updated":None}

def parse_header(data):
    if len(data) < HEADER: return None
    fmt, year, major, minor, version, pid = struct.unpack_from("<HBBBBB", data, 0)
    session_uid = struct.unpack_from("<Q", data, 8)[0]
    session_time = struct.unpack_from("<f", data, 16)[0]
    frame, overall = struct.unpack_from("<II", data, 20)
    player, secondary = struct.unpack_from("<BB", data, 28)
    return {"format":fmt,"year":year,"pid":pid,"uid":session_uid,
            "time":session_time,"frame":frame,"player":player}

def finite(v):
    return v if isinstance(v,(int,float)) and (v == v) and abs(v) != float("inf") else None

def parse_packet(data):
    h = parse_header(data)
    if not h or h["format"] != 2026 or h["pid"] not in PACKET_LENGTHS: return None
    if len(data) != PACKET_LENGTHS[h["pid"]]: return None
    pid, idx = h["pid"], h["player"]
    if idx >= CARS: return None
    if pid in (0,13): return None
    with lock:
        if state.get("sessionUid") != h["uid"]:
            state.update(sessionUid=h["uid"],trackId=None,trackName=None,sessionName=None,
                         mapReady=False,bestLapMs=None)
        if pid == 1:
            # session packet fixed fields before marshal-zone array
            track_length = struct.unpack_from("<H",data,33)[0]
            session_type = data[35]
            track_id = struct.unpack_from("<b",data,36)[0]
            safety = data[HEADER+125] # after fixed fields and 21 five-byte marshal zones
            state["trackId"] = track_id if track_id >= 0 else None
            state["trackName"] = ("TRACK "+str(track_id)) if track_id >= 0 else None
            state["sessionName"] = SESSION_TYPES.get(session_type,"SESSION")
            state["trackLength"] = track_length
            state["safetyCar"] = {0:None,1:"SAFETY CAR",2:"VSC",3:"FORMATION"}.get(safety)
        elif pid == 2:
            off = HEADER + idx*57
            state["lastLapMs"] = struct.unpack_from("<I",data,off)[0] or None
            state["currentLapMs"] = struct.unpack_from("<I",data,off+4)[0] or None
            s1ms, s1min = struct.unpack_from("<HB",data,off+8)
            s2ms, s2min = struct.unpack_from("<HB",data,off+11)
            state["sectors"]=[s1ms+s1min*60000,s2ms+s2min*60000,None]
            state["safetyDelta"] = finite(struct.unpack_from("<f",data,off+28)[0])
            state["position"]=data[off+32] or None
            state["lap"]=data[off+33] or None
        elif pid == 6:
            off = HEADER + idx*59
            state["speed"]=struct.unpack_from("<H",data,off)[0]
            throttle=finite(struct.unpack_from("<f",data,off+2)[0])
            brake=finite(struct.unpack_from("<f",data,off+10)[0])
            state["throttle"]=round(max(0,min(1,throttle))*100) if throttle is not None else None
            state["brake"]=round(max(0,min(1,brake))*100) if brake is not None else None
            state["gear"]=struct.unpack_from("<b",data,off+15)[0]
            state["rpm"]=struct.unpack_from("<H",data,off+16)[0]
            maxrpm=state.get("maxRpm")
            state["rpmPercent"]=min(100,state["rpm"]*100/maxrpm) if maxrpm else None
            state["tyreTemps"]=list(data[off+32:off+34])+list(data[off+30:off+32])
        elif pid == 7:
            off = HEADER + idx*59
            fuel=finite(struct.unpack_from("<f",data,off+5)[0])
            state["fuelKg"]=round(fuel,1) if fuel is not None else None
            state["maxRpm"]=struct.unpack_from("<H",data,off+17)[0]
            state["compound"]=str(data[off+26])
            flag=struct.unpack_from("<b",data,off+28)[0]
            state["flag"]=FLAG_NAMES.get(flag,"--")
            energy=struct.unpack_from("<f",data,off+37)[0]
            state["ersKj"]=round(energy/1000,1) if finite(energy) is not None and energy >= 0 else None
            state["ersMode"]={0:"NONE",1:"MEDIUM",2:"HOTLAP",3:"BOOST"}.get(data[off+41],"--")
            harvest=finite(struct.unpack_from("<f",data,off+42)[0])
            harvest_h=finite(struct.unpack_from("<f",data,off+46)[0])
            deployed=finite(struct.unpack_from("<f",data,off+54)[0])
            state["harvestKj"]=round((harvest+harvest_h)/1000,1) if harvest is not None and harvest_h is not None else None
            state["deployKj"]=round(deployed/1000,1) if deployed is not None else None
        elif pid == 10:
            off = HEADER + idx*46
            wear = list(struct.unpack_from("<4f",data,off))
            wear = wear[2:4] + wear[0:2] # UDP wheel order RL, RR, FL, FR
            state["tyreWear"] = [round(max(0,min(100,v)),1) for v in wear]
        elif pid == 14:
            # Personal best data set follows the session best data set.
            off = HEADER + 25
            valid = data[off+24]
            lap_ms = struct.unpack_from("<I",data,off+3)[0]
            if valid == 1 and lap_ms > 0: state["bestLapMs"] = lap_ms
        elif pid == 16:
            off = HEADER + idx*10
            mode, available = data[off], data[off+1]
            distance = struct.unpack_from("<H",data,off+2)[0]
            overtake_available, overtake_active = data[off+4], data[off+5]
            overtake_distance = struct.unpack_from("<H",data,off+6)[0]
            state["straightMode"] = ("STRAIGHT" if mode == 1 else "CORNER") if available else "UNAVAILABLE"
            state["aeroDistance"] = distance if distance else None
            state["overtake"] = ("ACTIVE" if overtake_active else "AVAILABLE") if overtake_active or overtake_available else "UNAVAILABLE"
            state["overtakeDistance"] = overtake_distance if overtake_distance else None
        elif pid == 3:
            code = data[HEADER:HEADER+4].decode("ascii","ignore")
            if code == "RDFL": state["flag"] = "RED"
            elif code == "CHQF": state["flag"] = "CHEQUERED"
            elif code in ("SSTA","SEND"): state["flag"] = "GREEN"
        state["status"]="LIVE"
        state["updated"]=time.time()
        return dict(state)

def ws_frame(payload):
    n=len(payload)
    head=bytes([0x81,n]) if n<126 else bytes([0x81,126])+struct.pack("!H",n) if n<65536 else bytes([0x81,127])+struct.pack("!Q",n)
    return head+payload

def broadcast(snapshot):
    raw=ws_frame(json.dumps(snapshot,separators=(",",":"),allow_nan=False).encode())
    with lock: targets=list(clients)
    for sock in targets:
        try: sock.sendall(raw)
        except OSError:
            with lock: clients.discard(sock)
            try:sock.close()
            except OSError:pass

class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*args): pass
    def do_GET(self):
        if self.path=="/ws":
            key=self.headers.get("Sec-WebSocket-Key")
            if not key or self.headers.get("Upgrade","").lower()!="websocket":
                self.send_error(400);return
            accept=base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101,"Switching Protocols")
            self.send_header("Upgrade","websocket");self.send_header("Connection","Upgrade")
            self.send_header("Sec-WebSocket-Accept",accept);self.end_headers()
            sock=self.connection
            with lock: clients.add(sock)
            try:
                while sock.recv(1024): pass
            except OSError: pass
            finally:
                with lock: clients.discard(sock)
            return
        path="/" if self.path=="/" else self.path.lstrip("/")
        if path not in ("index.html","app.js","style.css"): self.send_error(404);return
        body=(ROOT/path).read_bytes()
        kinds={".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",".css":"text/css; charset=utf-8"}
        self.send_response(200);self.send_header("Content-Type",kinds[Path(path).suffix])
        self.send_header("Content-Length",str(len(body)));self.send_header("Cache-Control","no-store")
        self.end_headers();self.wfile.write(body)

def udp_loop():
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    sock.bind(("0.0.0.0",UDP_PORT))
    print(f"F1 2026 UDP listening on 0.0.0.0:{UDP_PORT}")
    while True:
        data,_=sock.recvfrom(65535)
        parsed=parse_packet(data)
        if parsed: broadcast(parsed)

if __name__=="__main__":
    threading.Thread(target=udp_loop,daemon=True).start()
    print(f"Fermaxo display: http://0.0.0.0:{HTTP_PORT}")
    ThreadingHTTPServer(("0.0.0.0",HTTP_PORT),Handler).serve_forever()
