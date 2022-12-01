package zip

import "core:io"
import "core:math"
import "core:hash"
import "core:strings"
import "vendor:zlib"
import "core:time"
import "core:bufio"

Writer :: struct {
  w: io.Writer,
  bw: bufio.Writer,
  written: uint,
  zs: zlib.z_stream,
  comment: string,

  _buf: [dynamic]byte,
  _curr: ^FileWriterContext,

  _files: [dynamic]FileData,
}

@(private)
FileData :: struct {
  name: string,
  comment: string,
  compressedSize: uint,
  uncompressedSize: uint,
  offset: uint,
  crc32: u32,
  method: u16,
  time: u16,
  date: u16,
}

@(private)
FileWriterContext :: struct {
  w: io.Writer,
  bw: ^bufio.Writer,
  zWriter: ^Writer,
  zs: ^zlib.z_stream,
  buf: ^[dynamic]byte,
  headerWritten: bool,

  using data: FileData,
}

new_writer :: proc(writer: io.Writer) -> (res: ^Writer) {
  res = new(Writer)
  res.w = writer
  bufio.writer_init(&res.bw, writer)
  zlib.deflateInit2(&res.zs, zlib.DEFAULT_COMPRESSION, zlib.DEFLATED, -15, 8, zlib.DEFAULT_STRATEGY)

  BUF_SIZE :: 4096
  res._buf = make([dynamic]byte, BUF_SIZE)

  return
}

set_comment :: proc(writer: ^Writer, comment: string) -> Error {
  if len(comment) > 0xffff {
    return .Comment_Too_Long
  }

  delete(writer.comment)
  writer.comment = strings.clone(comment)

  return nil
}

writer_close :: proc(writer: ^Writer) -> (err: Error) {
  e := close_file_writer(writer._curr)
  if e != nil {
    return e
  }

  cdOffs := writer.written
  cdSize: uint

  for f in writer._files {
    defer delete(f.name)
    defer delete(f.comment)

    compressedSize := f.compressedSize
    uncompressedSize := f.uncompressedSize
    offset := f.offset
    z64 := compressedSize >= 0xffffffff || uncompressedSize >= 0xffffffff || offset >= 0xffffffff

    header: CentralDirectoryFileHeader
    header.signature = 0x02014b50
    header.versionMadeBy = 100 // Just gonna set it some arbitrary value not used by any popular zip writers
    header.versionNeeded = 100
    header.flags = 1<<3 // This inidicates that data descriptor is present
    header.compressionMethod = f.method
    header.lastModifiedTime = f.time
    header.lastModifiedDate = f.date
    header.crc32 = f.crc32
    header.compressedSize = u32(math.min(compressedSize, 0xffffffff))
    header.uncompressedSize = u32(math.min(uncompressedSize, 0xffffffff))
    header.fileNameLength = u16(len(f.name))
    header.fileCommentLength = u16(len(f.comment))
    header.relOffsetOfLocalHeader = u32(math.min(offset, 0xffffffff))
    if z64 {
      header.extraLength = size_of(ExtraFieldHeader) + size_of(CentralDirectoryFileHeader64)
    }

    cds := transmute([size_of(CentralDirectoryFileHeader)]byte)header
    n, werr := bufio.writer_write(&writer.bw, cds[:])
    cdSize += uint(n)
    if werr != nil {
      return .Write_Error
    }

    n, werr = bufio.writer_write_string(&writer.bw, f.name)
    cdSize += uint(n)
    if werr != nil {
      return .Write_Error
    }

    if z64 {
      extra: struct {
        using h: ExtraFieldHeader,
        using c: CentralDirectoryFileHeader64,
      }
      extra.header = 0x0001
      extra.uncompressedSize = u64(uncompressedSize)
      extra.compressedSize = u64(compressedSize)
      extra.offsetOfLocalHeader = u64(offset)

      s := 8 // Always write uncompressed size
      if offset >= 0xffffffff {
        s += 24 // Write compressed size and data offset
      }
      else if compressedSize >= 0xffffffff {
        s += 16 // Write compressed size
      }

      extra.size = u16(s)

      es := transmute([size_of(extra)]byte)extra
      n, werr = bufio.writer_write(&writer.bw, es[:size_of(ExtraFieldHeader) + s])
      cdSize += uint(n)
      if werr != nil {
        return .Write_Error
      }
    }

    n, werr = bufio.writer_write_string(&writer.bw, f.comment)
    cdSize += uint(n)
    if werr != nil {
      return .Write_Error
    }
  }

  writer.written += cdSize

  zip64 := cdSize >= 0xffffffff || len(writer._files) >= 0xffff
  if zip64 {
    eocd64Loc := writer.written
    eocd64: EOCD64
    eocd64.signature = 0x06064b50
    eocd64.sizeOfEOCD = size_of(EOCD64) - 12
    eocd64.numberDirRecordsOnDisk = u64(len(writer._files))
    eocd64.numberDirRecords = u64(len(writer._files))
    eocd64.sizeOfCentralDirectory = u64(cdSize)
    eocd64.centralDirectoryStartOffset = u64(cdOffs)

    {
      es := transmute([size_of(eocd64)]byte)eocd64
      n, werr := bufio.writer_write(&writer.bw, es[:])
      writer.written += uint(n)
      if werr != nil {
        return .Write_Error
      }
    }

    loc: EOCD64Locator
    loc.signature = 0x07064b50
    loc.eocd64Offset = u64(eocd64Loc)

    {
      es := transmute([size_of(loc)]byte)loc
      n, werr := bufio.writer_write(&writer.bw, es[:])
      writer.written += uint(n)
      if werr != nil {
        return .Write_Error
      }
    }
  }

  eocd: EOCD
  eocd.signature = 0x06054b50
  eocd.numberDirRecordsOnDisk = u16(math.min(len(writer._files), 0xffff))
  eocd.numberDirRecords = u16(math.min(len(writer._files), 0xffff))
  eocd.sizeOfCentralDirectory = u32(math.min(cdSize, 0xffffffff))
  eocd.centralDirectoryOffset = u32(math.min(cdOffs, 0xffffffff))
  eocd.commentLength = u16(len(writer.comment))

  eocds := transmute([size_of(EOCD)]byte)eocd
  n, werr := bufio.writer_write(&writer.bw, eocds[:])
  writer.written += uint(n)
  if werr != nil {
    return .Write_Error
  }

  n, werr = bufio.writer_write_string(&writer.bw, writer.comment)
  writer.written += uint(n)
  if werr != nil {
    return .Write_Error
  }

  werr = bufio.writer_flush(&writer.bw)
  if werr != nil {
    return .Flush_Error
  }
  bufio.writer_destroy(&writer.bw)

  if writer._curr != nil {
    free(writer._curr)
  }
  delete(writer._files)
  delete(writer._buf)
  delete(writer.comment)

  free(writer)

  return
}

create_file :: proc(writer: ^Writer, name: string) -> (w: io.Writer, err: Error) {
  return create_file_extra(writer, FileInfo{
    name = name,
    method = 8, // Use DEFLATE compression by default
  })
}

FileInfo :: struct {
  name: string,
  comment: string,

  method: int, // Compression method. 8 - deflate(zlib compression); 0 - store(no compression)

  // File date and time. If not provided, it will be set to current date and time in UTC +0
  lastModifiedDateTime: time.Time,
}

create_file_extra :: proc(writer: ^Writer, info: FileInfo) -> (w: io.Writer, err: Error) {
  if len(info.name) > 0xffff {
    err = .Name_Too_Long
    return
  }

  if len(info.comment) > 0xffff {
    err = .Comment_Too_Long
    return
  }

  close_file_writer(writer._curr)

  vt: ^io.Stream_VTable
  switch info.method {
    case 0: // STORE
      vt = &_file_writer_store_stream_vtable
    case 8: // DEFLATE
      vt = &_file_writer_deflate_stream_vtable
    case:
      err = .Unsupported_Compression_Method
      return
  }

  ctx := writer._curr
  if ctx == nil {
    ctx = new(FileWriterContext)
    writer._curr = ctx
  }

  ctx.buf = &writer._buf
  ctx.bw = &writer.bw
  ctx.zs = &writer.zs

  ctx.name = strings.clone(info.name)
  ctx.comment = strings.clone(info.comment)
  ctx.method = u16(info.method)

  dateTime: time.Time
  if info.lastModifiedDateTime == dateTime {
    dateTime = time.now()
  }

  ctx.time = to_dos_time(dateTime)
  ctx.date = to_dos_date(dateTime)

  ctx.zWriter = writer
  ctx.offset = writer.written

  writer._curr = ctx

  w.stream_data = ctx
  w.stream_vtable = vt

  ctx.w = w

  return
}

@(private)
write_header :: proc(ctx: ^FileWriterContext, method: u16) -> (err: io.Error) {
  if ctx.headerWritten {
    return
  }

  ctx.method = method

  writer := ctx.zWriter
  header: LocalFileHeader
  header.signature = 0x04034b50
  header.versionNeeded = 100
  header.flags = 1<<3
  header.compressionMethod = method
  header.fileNameLength = u16(len(ctx.name))

  // These are assumed to not be known in advance to support streaming.
  // We put these values into the data descriptor after all the data has been written.
  // header.compressedSize = 0
  // header.uncompressedSize = 0
  // header.crc32 = 0

  ha := transmute([size_of(LocalFileHeader)]byte)header
  n: int
  n, err = bufio.writer_write(&writer.bw, ha[:])
  writer.written += uint(n)
  if err != nil {
    return
  }

  n, err = bufio.writer_write_string(&writer.bw, ctx.name)
  writer.written += uint(n)
  if err != nil {
    return
  }

  ctx.headerWritten = true

  return
}

@(private)
to_dos_date :: proc(t: time.Time) -> (res: u16) {
  // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-filetimetodosdatetime
  d := time.day(t)
  m := time.month(t)
  y := time.year(t)

  res |= u16(d & 0b11111)
  res |= u16((int(m) & 0b1111) << 5)
  res |= u16((y-1980) << 9)

  return
}

@(private)
to_dos_time :: proc(t: time.Time) -> (res: u16) {
  // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-filetimetodosdatetime
  h, m, s := time.clock_from_time(t)

  res |= u16((s/2) & 0b11111)
  res |= u16((m & 0b111111) << 5)
  res |= u16(h << 11)

  return
}

@(private)
close_file_writer :: proc(ctx: ^FileWriterContext) -> (err: Error) {
  if ctx == nil {
    return
  }

  if ctx.compressedSize == 0 {
    err := write_header(ctx, 0)
    if err != nil {
      return .Write_Error
    }
  }

  io.close(io.to_closer(ctx.w.stream))

  append(&ctx.zWriter._files, ctx.zWriter._curr.data)

  // To support streaming, we write data size and crc32 to data descriptor after the end of the data stream
  n: int
  werr: io.Error
  if ctx.uncompressedSize > 0xffffffff || ctx.compressedSize > 0xffffffff {
    d: DataDescriptor64
    d.signature = 0x08074b50
    d.crc32 = ctx.crc32
    d.compressedSize = u64(ctx.compressedSize)
    d.uncompressedSize = u64(ctx.uncompressedSize)

    dd := transmute([size_of(DataDescriptor64)]byte)d
    n, werr = bufio.writer_write(ctx.bw, dd[:])
    if werr != nil {
      return .Write_Error
    }
  }
  else {
    d: DataDescriptor
    d.signature = 0x08074b50
    d.crc32 = ctx.crc32
    d.compressedSize = u32(ctx.compressedSize)
    d.uncompressedSize = u32(ctx.uncompressedSize)

    dd := transmute([size_of(DataDescriptor)]byte)d
    n, werr = bufio.writer_write(ctx.bw, dd[:])
    if werr != nil {
      return .Write_Error
    }
  }

  ctx.zWriter.written += uint(n)

  ctx^ = {}

  return
}

@(private)
write_deflate :: proc(ctx: ^FileWriterContext, p: []byte) -> (n: int, err: io.Error) {
  if len(p) == 0 {
    return
  }

  if ctx.compressedSize == 0 {
    err = write_header(ctx, 8)
    if err != nil {
      return
    }
  }

  zs := ctx.zs

  ctx.crc32 = hash.crc32(p, ctx.crc32)

  currIn: uint
  currOut: uint

  for {
    zs.next_in = &p[currIn]
    zs.next_out = &ctx.buf[0]

    // Make sure not to overflow when reading more than 4 gigs of data
    zs.avail_in = u32(math.min(uint(len(p))-currIn, 0xffffffff))
    zs.avail_out = u32(len(ctx.buf))

    zs.total_in = 0
    zs.total_out = 0

    e := zlib.deflate(zs, zlib.BLOCK)

    currIn += uint(zs.total_in)
    currOut += uint(zs.total_out)

    ctx.compressedSize += currOut
    ctx.uncompressedSize += currIn

    if e != 0 {
      break
    }

    nw: int
    nw, err = bufio.writer_write(ctx.bw, ctx.buf[:currOut])
    ctx.zWriter.written += uint(nw)

    if err != nil {
      return
    }

    if currIn == len(p) {
      break
    }
  }

  n = int(currIn)

  return
}

@(private)
write_store :: proc(ctx: ^FileWriterContext, p: []byte) -> (n: int, err: io.Error) {
  if len(p) == 0 {
    return
  }

  if ctx.compressedSize == 0 {
    err = write_header(ctx, 0)
    if err != nil {
      return
    }
  }

  ctx.crc32 = hash.crc32(p, ctx.crc32)

  n, err = bufio.writer_write(ctx.bw, p[:])
  ctx.compressedSize   += uint(n)
  ctx.uncompressedSize += uint(n)
  ctx.zWriter.written  += uint(n)
  if err != nil {
    return
  }

  return
}

@(private)
close_deflate :: proc(ctx: ^FileWriterContext) -> io.Error {
  zs := ctx.zs

  zs.total_out = 0
  zs.total_in = 0

  zs.next_out = &ctx.buf[0]

  zlib.deflate(zs, zlib.FINISH)
  n, err := bufio.writer_write(ctx.bw, ctx.buf[:zs.total_out])
  ctx.zWriter.written += uint(n)
  if err != nil {
    return err
  }

  ctx.uncompressedSize += uint(zs.total_in)
  ctx.compressedSize += uint(zs.total_out)

  zlib.deflateReset(zs)

  return nil
}

@(private)
close_store :: proc(ctx: ^FileWriterContext) -> io.Error {
  return nil
}

@(private)
_file_writer_deflate_stream_vtable := io.Stream_VTable{
  impl_write = proc(s: io.Stream, p: []byte) -> (n: int, err: io.Error) {
    return write_deflate((^FileWriterContext)(s.stream_data), p)
  },
  impl_close = proc(s: io.Stream) -> io.Error {
    return close_deflate((^FileWriterContext)(s.stream_data))
  },
}

@(private)
_file_writer_store_stream_vtable := io.Stream_VTable{
  impl_write = proc(s: io.Stream, p: []byte) -> (n: int, err: io.Error) {
    return write_store((^FileWriterContext)(s.stream_data), p)
  },
}
