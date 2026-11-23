import Darwin
import Foundation

/// mach_absolute_time ベースのホスト時計。
/// 両トラック（system / mic）を同一タイムラインに乗せる基準として使う（SPEC §4.3）。
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// 現在のホスト時刻（tick）。
    public static func now() -> UInt64 { mach_absolute_time() }

    /// ホスト時刻（tick）を秒に変換する。
    public static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// 秒をホスト時刻（tick）に変換する。
    public static func hostTime(fromSeconds seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// 現在時刻（秒）。
    public static func nowSeconds() -> Double { seconds(fromHostTime: now()) }
}
