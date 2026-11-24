//! Incremental line splitting for a tailer.
//!
//! Claude Code appends one JSON object per line and ends every line with `\n`. A tailer may read a
//! file while a line is still being written, so the bytes after the last `\n` are held back until
//! their newline arrives. They are never handed out as a line.

/// Buffers raw bytes and yields only complete lines (without the trailing `\n` / `\r\n`).
#[derive(Debug, Default)]
pub struct LineBuffer {
    pending: Vec<u8>,
    /// Bytes handed out as lines so far (with their newlines): the absolute file offset of
    /// `pending[0]` when the buffer was fed from byte 0.
    consumed: u64,
}

/// One complete line and where it sits in the stream fed to the [`LineBuffer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub text: String,
    /// Absolute offset of the line's first byte.
    pub offset: u64,
    /// Length in bytes, without the trailing `\n` / `\r\n`.
    pub len: u64,
}

impl LineBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed newly read bytes. Returns every line completed by them, in order. Invalid UTF-8 is
    /// replaced (lossy), never an error.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<String> {
        self.push_lines(bytes).into_iter().map(|l| l.text).collect()
    }

    /// Like [`LineBuffer::push`], with each line's absolute offset and byte length. Offsets count
    /// every byte ever fed, so they stay right when a line is split across two reads.
    pub fn push_lines(&mut self, bytes: &[u8]) -> Vec<Line> {
        self.pending.extend_from_slice(bytes);
        let Some(last_nl) = self.pending.iter().rposition(|&b| b == b'\n') else {
            return Vec::new();
        };
        let rest = self.pending.split_off(last_nl + 1);
        let done = std::mem::replace(&mut self.pending, rest);
        let mut at = self.consumed;
        self.consumed += done.len() as u64;
        done[..done.len() - 1]
            .split(|&b| b == b'\n')
            .map(|raw| {
                let offset = at;
                at += raw.len() as u64 + 1;
                let l = raw.strip_suffix(b"\r").unwrap_or(raw);
                Line {
                    text: String::from_utf8_lossy(l).into_owned(),
                    offset,
                    len: l.len() as u64,
                }
            })
            .collect()
    }

    /// Bytes held back because their line has no newline yet.
    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_line_is_held_until_newline() {
        let mut b = LineBuffer::new();
        assert!(b.push(b"{\"type\":\"mo").is_empty());
        assert_eq!(b.pending_len(), 11);
        assert_eq!(b.push(b"de\"}\n{\"a\""), vec!["{\"type\":\"mode\"}"]);
        assert_eq!(b.pending_len(), 4);
        assert_eq!(b.push(b":1}\r\n\n"), vec!["{\"a\":1}", ""]);
        assert_eq!(b.pending_len(), 0);
    }

    #[test]
    fn many_lines_in_one_chunk_keep_order() {
        let mut b = LineBuffer::new();
        assert_eq!(b.push(b"a\nb\nc\nd"), vec!["a", "b", "c"]);
        assert_eq!(b.push(b"\n"), vec!["d"]);
    }

    #[test]
    fn offsets_are_absolute_across_split_reads() {
        let stream = b"{\"a\":1}\r\n{\"bb\":22}\n{\"c\":3}\n";
        let mut b = LineBuffer::new();
        let mut got = b.push_lines(&stream[..12]); // first line + part of the second
        got.extend(b.push_lines(&stream[12..16])); // second line still split
        got.extend(b.push_lines(&stream[16..]));
        assert_eq!(got.len(), 3);
        for l in &got {
            let at = l.offset as usize;
            assert_eq!(&stream[at..at + l.len as usize], l.text.as_bytes(), "{l:?}");
        }
        assert_eq!(got[1].offset, 9);
        assert_eq!(got[2].offset, 19);
    }

    #[test]
    fn invalid_utf8_is_lossy_not_a_panic() {
        let mut b = LineBuffer::new();
        let out = b.push(b"\xff\xfe ok\n");
        assert_eq!(out.len(), 1);
        assert!(out[0].ends_with(" ok"));
    }
}
