//! Minimal RFC 3339 timestamp parsing (`2030-03-14T09:26:53.589Z`, or with a `±hh:mm` offset)
//! to Unix milliseconds. Kept tiny on purpose: no date crate for one format.

/// Parse an RFC 3339 timestamp to Unix epoch milliseconds. `None` if it is not one.
pub fn parse_ms(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't' | b' ') {
        return None;
    }
    if b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> { s.get(r)?.parse::<i64>().ok() };
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    let mut i = 19;
    let mut ms = 0i64;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return None;
        }
        let frac = &s[start..i.min(start + 3)];
        ms = frac.parse::<i64>().ok()? * 10i64.pow(3 - frac.len() as u32);
    }
    let offset_min = match b.get(i)? {
        b'Z' | b'z' if i + 1 == b.len() => 0,
        sign @ (b'+' | b'-') if i + 6 == b.len() && b[i + 3] == b':' => {
            let v = num(i + 1..i + 3)? * 60 + num(i + 4..i + 6)?;
            if *sign == b'+' { v } else { -v }
        }
        _ => return None,
    };
    let days = days_from_civil(y, mo, d);
    Some(((days * 86_400 + h * 3600 + mi * 60 + sec - offset_min * 60) * 1000) + ms)
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::parse_ms;

    #[test]
    fn known_instants() {
        assert_eq!(parse_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_ms("1970-01-01T00:00:00.5Z"), Some(500));
        // `date -u -d 2030-03-14T09:26:53Z +%s` = 1899710813
        assert_eq!(
            parse_ms("2030-03-14T09:26:53.589Z"),
            Some(1_899_710_813_589)
        );
        assert_eq!(
            parse_ms("2030-03-14T03:26:53.589-06:00"),
            Some(1_899_710_813_589)
        );
        assert_eq!(parse_ms("2000-03-01T00:00:00Z"), Some(951_868_800_000));
    }

    #[test]
    fn garbage_is_none() {
        for s in [
            "",
            "yesterday",
            "2030-03-14",
            "2030-13-01T00:00:00Z",
            "2030-03-14T09:26:53",
            "2030-03-14T09:26:53.Z",
            "2030-03-14T09:26:53Zjunk",
        ] {
            assert_eq!(parse_ms(s), None, "{s}");
        }
    }
}
