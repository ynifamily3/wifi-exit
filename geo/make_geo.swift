// make_geo.swift: DB-IP "IP to Country Lite" CSV (stdin, IPv4·IPv6 섞임) → ipv4-country.bin
//   gzip -dc dbip-country-lite-YYYY-MM.csv.gz | swift make_geo.swift ipv4-country.bin
// 파일 모양 (리틀 엔디언): "WXG1" · 개수 n (UInt32) · 시작 주소 n개 (UInt32, 오름차순) · 나라 코드 n개 (2바이트 ASCII)
// 이웃한 같은 나라 구간은 하나로 합친다. 나라를 모르는 구간은 "ZZ".
import Foundation

func ipv4(_ s: Substring) -> UInt32? {
    let p = s.split(separator: ".")
    guard p.count == 4 else { return nil }
    var n: UInt32 = 0
    for x in p { guard let v = UInt32(x), v < 256 else { return nil }; n = n << 8 | v }
    return n
}

var starts: [UInt32] = [], codes: [UInt16] = []
var lines = 0
while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: ",")
    guard f.count >= 3, let a = ipv4(f[0]) else { continue }       // IPv6 줄은 건너뛴다
    let cc = f[2].utf8.count == 2 ? f[2].uppercased() : "ZZ"
    let code = UInt16(cc.utf8.first!) << 8 | UInt16(cc.utf8.dropFirst().first!)
    lines += 1
    if let last = codes.last, last == code { continue }
    starts.append(a); codes.append(code)
}
guard !starts.isEmpty, zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else {
    FileHandle.standardError.write("입력이 비었거나 주소 순서가 어긋났어요\n".data(using: .utf8)!); exit(1)
}
var out = Data("WXG1".utf8)
var n = UInt32(starts.count).littleEndian
out.append(Data(bytes: &n, count: 4))
for var s in starts { s = s.littleEndian; out.append(Data(bytes: &s, count: 4)) }
for c in codes { out.append(UInt8(c >> 8)); out.append(UInt8(c & 0xff)) }
try out.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("IPv4 \(lines)줄 → 구간 \(starts.count)개, \(out.count) 바이트")
