#define uint32_t uint

#define TEX_HEADER_SIZE 0x50
#define NUM_THREADS 1024

#define MAXBITS 15              /* maximum bits in a code */
#define MAXLCODES 286           /* maximum number of literal/length codes */
#define MAXDCODES 30            /* maximum number of distance codes */
#define MAXCODES (MAXLCODES+MAXDCODES)  /* maximum codes lengths to read */
#define FIXLCODES 288           /* number of fixed literal/length codes */

ByteAddressBuffer BufIn : register(t0);
RWByteAddressBuffer BufOut : register(u0);

int Fail(int errorCode) {
    // TODO: write error to some buffer
    //BufOut.Store(20, errorCode);
    //abort();
    return errorCode;
}

struct BitReader {
    uint32_t m_byteBaseOffset;
    uint32_t m_byteOffset;
    uint32_t m_byteLength;
    uint32_t m_bufBitCount;
    uint64_t m_buf;

    inline void Init(uint32_t offset, uint32_t length) {
        m_byteBaseOffset = offset;
        m_byteOffset = 0;
        m_byteLength = length;
        m_bufBitCount = 0;
        m_buf = 0;
    }
   
    int LoadNext32() {
        if (m_byteOffset >= m_byteLength)
            return Fail(-12);  /* not enough input */
        if (m_bufBitCount > 32)
            return 0;          /* no need to refill */

        m_buf |= ((uint64_t)BufIn.Load(m_byteBaseOffset + m_byteOffset) << m_bufBitCount);
        m_bufBitCount += 32;
        m_byteOffset += 4;
        return 0;
    }

    inline void Drain(uint32_t n) {
        m_bufBitCount -= n;
        m_buf >>= n;
    }

    inline uint32_t Peek(uint32_t n) {
        if (m_bufBitCount < n) {
            const int lnres = LoadNext32();
            if (lnres != 0)
                return Fail(lnres);
        }

        return (uint32_t)m_buf & ((1u << n) - 1);
    }

    inline uint32_t Read(uint32_t n) {
        const uint32_t res = Peek(n);
        Drain(n);
        return res;
    }

	inline uint32_t ReadAssumeAvailable(uint32_t n) {
		const uint32_t res = (uint32_t)m_buf & ((1u << n) - 1u);
		Drain(n);
		return res;
	}

    inline void AlignToByte() {
        const uint32_t n = m_bufBitCount & 7;
        if (n)
            Drain(n);
    }
};

struct OutState {
    uint32_t m_baseOffset;
    uint32_t m_capacity;
    uint32_t m_offset;

    uint32_t m_bufLen;
    uint32_t m_buf;

    void Init(uint32_t baseOffset, uint32_t capacity) {
        m_baseOffset = baseOffset;
        m_capacity = capacity;
        m_offset = 0;
        m_bufLen = 0;
        m_buf = 0;
    }

    inline uint32_t GetByteAt(uint32_t offset) {
        if (m_offset <= offset && offset < m_offset + m_bufLen)
            return (m_buf >> ((offset - m_offset) * 8)) & 0xFF;
        offset += m_baseOffset;
        return (BufOut.Load(offset & ~3) >> ((offset & 3) << 3)) & 0xFF;
    }

    inline int AppendByte(uint32_t value) {
        m_buf |= (value << (m_bufLen << 3));
        m_bufLen++;
        return Flush();
    }

    inline int RepeatBytes(uint32_t dist, uint32_t length) {
        if (dist > m_offset + m_bufLen)
            return Fail(-11);       /* distance too far back */

        uint32_t offset = m_offset + m_bufLen - dist;
        
        for (uint32_t i = 0; i < length; i++)
            AppendByte(GetByteAt(offset++));

        return length;
    }
    
    inline int CopyBytesFrom(inout BitReader br, uint32_t length) {
        if (length == 0)
            return 0;

        uint32_t i = 0;
        if (m_bufLen > 0) {
            if (m_bufLen == 1 && length >= 3) {
                m_buf |= (br.Read(24) << 8);
                m_bufLen += 3;
                i = 3;
            } else if (m_bufLen == 2 && length >= 2) {
                m_buf |= (br.Read(16) << 16);
                m_bufLen += 2;
                i = 2;
            } else if (m_bufLen == 3 && length >= 1) {
                m_buf |= (br.Read(8) << 24);
                m_bufLen += 1;
                i = 1;
            } else if (m_bufLen > 0) {
                m_buf |= (br.Read(length << 3) << (m_bufLen << 3));
                m_bufLen += length;
                return length;
            }
        }

        Flush();
        for (uint32_t to = length - 3; i < to; i += 4) {
            BufOut.Store(m_baseOffset + m_offset, br.Read(32));
            m_offset += 4;
        }

        br.LoadNext32();
        [unroll(3)]
        for (; i < length; i++)
            AppendByte(br.ReadAssumeAvailable(8));
        return length;
    }

    int Flush() {
        if (m_bufLen < 4)
            return 1;
        BufOut.Store(m_baseOffset + m_offset, m_buf);
        m_bufLen = 0;
        m_buf = 0;
        m_offset += 4;
		return 1;
    }

    int FinalFlush() {
        if (m_bufLen == 0)
            return 1;

        uint32_t writeable = 4 - ((m_baseOffset + m_offset) & 3);
        BufOut.Store((m_baseOffset + m_offset) & ~3, m_buf);
		m_bufLen -= writeable;
		m_buf >>= (writeable << 3);
        m_offset += writeable;
		if (m_bufLen > 0) {
            BufOut.Store(m_baseOffset + m_offset, m_buf);
			m_offset += m_bufLen;
			m_bufLen = 0;
		}
		m_buf = 0;
		return 1;
    }
};

static uint32_t g_initHuffmanTable[MAXCODES];

struct HuffmanTable {
    uint32_t m_symbols[MAXCODES];
    uint32_t m_counts[MAXBITS + 1];

    int Init(uint32_t off, uint32_t n) {
        uint32_t symbol;         /* current symbol when stepping through length[] */
        uint32_t len;            /* current length when stepping through h->count[] */
        int left;           /* number of possible codes left of current length */
        int offs[MAXBITS+1];      /* offsets in symbol table for each length */

        /* count number of codes of each length */
        for (len = 0; len <= MAXBITS; len++)
            m_counts[len] = 0;
        for (symbol = 0; symbol < n; symbol++)
            m_counts[g_initHuffmanTable[off + symbol]]++;   /* assumes lengths are within bounds */
        if (m_counts[0] == n)               /* no codes! */
            return 0;                       /* complete, but decode() will fail */

        /* check for an over-subscribed or incomplete set of lengths */
        left = 1;                           /* one possible code of zero length */
        for (len = 1; len <= MAXBITS; len++) {
            left <<= 1;                     /* one more bit, double codes left */
            left -= m_counts[len];          /* deduct count from possible codes */
            if (left < 0)
                return left;                /* over-subscribed--return negative */
        }                                   /* left > 0 means incomplete */

        /* generate offsets into symbol table for each length for sorting */
        offs[1] = 0;
        for (len = 1; len < MAXBITS; len++)
            offs[len + 1] = offs[len] + m_counts[len];

        /*
         * put symbols in table sorted by length, by symbol order within each
         * length
         */
        for (symbol = 0; symbol < n; symbol++)
            if (g_initHuffmanTable[off + symbol] != 0)
                m_symbols[offs[g_initHuffmanTable[off + symbol]]++] = symbol;

        /* return zero for complete set, positive for incomplete set */
        return left;
    }

    int Decode(inout BitReader br) {
        int len;            /* current number of bits in code */
        int code;           /* len bits being decoded */
        int first;          /* first code of length len */
        int count;          /* number of codes of length len */
        int index;          /* index of first code of length len in symbol table */

        br.LoadNext32();

        code = first = index = 0;
        for (len = 1; len <= MAXBITS; len++) {
            code |= br.ReadAssumeAvailable(1);             /* get next bit */
            count = m_counts[len];
            if (code - count < first)       /* if length len, return symbol */
                return m_symbols[index + (code - first)];
            index += count;                 /* else update for next length */
            first += count;
            first <<= 1;
            code <<= 1;
        }

        return Fail(-10);
    }
};

static const int htpOrder[19] =        /* permutation of code length codes */
    {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
static const int htpLens[29] = { /* Size base for length codes 257..285 */
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const int htpLext[29] = { /* Extra bits for length codes 257..285 */
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const int htpDists[30] = { /* Offset base for distance codes 0..29 */
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577};
static const int htpDext[30] = { /* Extra bits for distance codes 0..29 */
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
    12, 12, 13, 13};

struct HuffmanTablePair {
    uint32_t m_initialized;
    HuffmanTable m_lengthCodeTable;
    HuffmanTable m_distanceCodeTable;

    void Clear() {
        m_initialized = 0;
    }

    void InitFixed() {
        if (m_initialized)
            return;
            
        m_initialized = 1;

        /* build fixed huffman tables */
        int symbol;

        /* literal/length table */
        for (symbol = 0; symbol < 144; symbol++)
            g_initHuffmanTable[symbol] = 8;
        for (; symbol < 256; symbol++)
            g_initHuffmanTable[symbol] = 9;
        for (; symbol < 280; symbol++)
            g_initHuffmanTable[symbol] = 7;
        for (; symbol < FIXLCODES; symbol++)
            g_initHuffmanTable[symbol] = 8;
        m_lengthCodeTable.Init(0, FIXLCODES);

        /* distance table */
        for (symbol = 0; symbol < MAXDCODES; symbol++)
            g_initHuffmanTable[symbol] = 5;
        m_distanceCodeTable.Init(0, MAXDCODES);
    }

    int InitDynamic(inout BitReader br) {
        uint32_t nlen, ndist, ncode;        /* number of lengths in descriptor */
        uint32_t index;                     /* index of lengths[] */
        int err;                            /* construct() return value */

        br.LoadNext32();

        /* get number of lengths in each table, check lengths */
        nlen = br.ReadAssumeAvailable(5) + 257;
        ndist = br.ReadAssumeAvailable(5) + 1;
        ncode = br.ReadAssumeAvailable(4) + 4;
        if (nlen > MAXLCODES || ndist > MAXDCODES)
            return -3;                      /* bad counts */

        /* read code length code lengths (really), missing lengths are zero */
        br.LoadNext32();
        if (ncode > 10) {
            for (index = 0; index <= 10; index++)
                g_initHuffmanTable[htpOrder[index]] = br.ReadAssumeAvailable(3);
            br.LoadNext32();
            for (; index < ncode; index++)
                g_initHuffmanTable[htpOrder[index]] = br.ReadAssumeAvailable(3);
        } else {
            for (index = 0; index < ncode; index++)
                g_initHuffmanTable[htpOrder[index]] = br.ReadAssumeAvailable(3);
        }

        for (; index < 19; index++)
            g_initHuffmanTable[htpOrder[index]] = 0;

        /* build huffman table for code lengths codes (use lencode temporarily) */
        err = m_lengthCodeTable.Init(0, 19);
        if (err != 0)                       /* require complete code set here */
            return Fail(-4);

        /* read length/literal and distance code length tables */
        for (index = 0; index < nlen + ndist;) {
            int symbol;                     /* decoded value */
            int len;                        /* last length to repeat */

            symbol = m_lengthCodeTable.Decode(br);
            if (symbol < 0)
                return Fail(symbol);        /* invalid symbol */
            if (symbol < 16)                /* length in 0..15 */
                g_initHuffmanTable[index++] = symbol;
            else {                          /* repeat instruction */
                len = 0;                    /* assume repeating zeros */
                if (symbol == 16) {         /* repeat last length 3..6 times */
                    if (index == 0)
                        return Fail(-5);    /* no last length! */
                    len = g_initHuffmanTable[index - 1];       /* last length */
                    symbol = 3 + br.Read(2);
                }
                else if (symbol == 17)      /* repeat zero 3..10 times */
                    symbol = 3 + br.Read(3);
                else                        /* == 18, repeat zero 11..138 times */
                    symbol = 11 + br.Read(7);
                if (index + symbol > nlen + ndist)
                    return Fail(-6);        /* too many lengths! */
                for (; symbol--;)           /* repeat last or zero symbol times */
                    g_initHuffmanTable[index++] = len;
            }
        }

        /* check for end-of-block code -- there better be one! */
        if (g_initHuffmanTable[256] == 0)
            return Fail(-9);

        /* build huffman table for literal/length codes */
        err = m_lengthCodeTable.Init(0, nlen);
        if (err && (err < 0 || nlen != m_lengthCodeTable.m_counts[0] + m_lengthCodeTable.m_counts[1]))
            return Fail(-7);      /* incomplete code ok only for single length 1 code */

        /* build huffman table for distance codes */
        err = m_distanceCodeTable.Init(nlen, ndist);
        if (err && (err < 0 || ndist != m_distanceCodeTable.m_counts[0] + m_distanceCodeTable.m_counts[1]))
            return Fail(-8);      /* incomplete code ok only for single length 1 code */

        return 0;
    }

    int DecompressOnce(inout BitReader br, inout OutState state, int symbol) {
        uint32_t len;           /* length for copy */
        uint32_t dist;          /* distance for copy */

        if (symbol < 256) {             /* literal: symbol is the byte */
            /* write out the literal */
            uint32_t abres = state.AppendByte(symbol);
            if (abres != 1)
                return Fail(-1);
        }
        else if (symbol > 256) {        /* length */
            /* get and compute length */
            symbol -= 257;
            if (symbol >= 29)
                return Fail(-10);       /* invalid fixed code */
            len = htpLens[symbol] + br.Read(htpLext[symbol]);

            /* get and check distance */
            symbol = m_distanceCodeTable.Decode(br);
            if (symbol < 0)
                return Fail(symbol);    /* invalid symbol */
            dist = htpDists[symbol] + br.Read(htpDext[symbol]);

            /* copy length bytes from distance bytes back */
            int repeated = state.RepeatBytes(dist, len);
            if (repeated < 0)
                return Fail(repeated);
            if ((uint32_t)repeated != len)
                return Fail(-1);         /* not enough output space */
        }

        return symbol;
    }

    uint32_t Decompress(inout BitReader br, inout OutState state) {
        int symbol = 0;         /* decoded symbol */
        /* decode literals and length/distance pairs */
        for (; symbol != 256;) {            /* end of block symbol */
            symbol = m_lengthCodeTable.Decode(br);
            if (symbol < 0)
                return Fail(symbol);        /* invalid symbol */

            symbol = DecompressOnce(br, state, symbol);
            if (symbol < 0)
                return Fail(symbol);
        }

        /* done with a valid fixed or dynamic block */
        return 0;
    }
};

struct Puff {
    BitReader m_br;
    OutState m_outState;
    HuffmanTablePair m_fixedTablePair;
    HuffmanTablePair m_dynamicTablePair;

    void Init(BitReader br, OutState outState) {
        m_fixedTablePair.Clear();
        m_dynamicTablePair.Clear();
        m_br = br;
        m_outState = outState;
    }

    int DoPuff() {
        int last, type, err;

        /* process blocks until last block or error */
        last = m_br.Read(1);         /* one if last block */
        type = m_br.Read(2);         /* block type 0..3 */
        if (type == 0)
            err = _DecompressStored();
        else if (type == 1)
            err = _DecompressFixed();
        else if (type == 2)
            err = _DecompressDynamic();
        else
            err = -1; /* type == 3, invalid */

        // our blocks always are single
        return err;
    }

    int _DecompressStored() {
        /* discard leftover bits from current byte (assumes state.bitcnt < 8) */
        m_br.AlignToByte();

        /* get length and check against its one's complement */
        const uint32_t len = m_br.Read(16);         /* length of stored block */
        if (m_br.Read(16) != (0xFFFF & ~len))
            return Fail(-2);                        /* didn't match complement! */

        /* copy len bytes from in to out */
        const uint32_t cpres = m_outState.CopyBytesFrom(m_br, len);
        if (cpres < 0)
            return Fail(cpres);
        if (cpres != len)
            return Fail(-1);                         /* not enough output space */

        /* done with a valid stored block */
        return 0;
    }

    int _DecompressFixed() {
        m_fixedTablePair.InitFixed();
        return m_fixedTablePair.Decompress(m_br, m_outState);
    }

    int _DecompressDynamic() {
        const int initRes = m_dynamicTablePair.InitDynamic(m_br);
        if (initRes != 0)
            return Fail(initRes);
        return m_dynamicTablePair.Decompress(m_br, m_outState);
    }
};

int DecompressBlock(inout uint32_t blockIndex, inout uint32_t blockSizeOffset, inout uint32_t decompOffset, inout uint32_t offset) {
    const uint4 header = BufIn.Load4(offset);
    const uint32_t headerSize = header.x;
    const uint32_t compressedSize = header.z;
    const uint32_t decompressedSize = header.w;
    
    int res;
    BitReader br;
    OutState outState;
    outState.Init(decompOffset, decompressedSize);
    
    if (compressedSize == 32000) {
        br.Init(offset + 0x10, decompressedSize);
        res = outState.CopyBytesFrom(br, decompressedSize);
    } else {
        br.Init(offset + 0x10, compressedSize);
        Puff puff;
        puff.Init(br, outState);
        res = puff.DoPuff();
    }
        
    outState.FinalFlush();
    blockIndex++;
    decompOffset += decompressedSize;
    offset += (BufIn.Load(blockSizeOffset & ~3) >> ((blockSizeOffset & 3) << 3)) & 0xFFFF;
    blockSizeOffset += 2;
    return res;
}

void FindOffsets(inout uint32_t blockSizeOffset, uint32_t subBlockIndex, uint32_t blockIndex, inout uint32_t decompOffset, inout uint32_t offset) {
    for (uint32_t j = subBlockIndex; j < blockIndex;) {
        if ((j & 1) == 1) {
            const uint32_t n = BufIn.Load(blockSizeOffset - 2);
            decompOffset += BufIn.Load(offset + 0x0C);
            offset += n >> 16;
            j++;
            blockSizeOffset += 2;
        } else if (j + 1 == blockIndex) {
            const uint32_t n = BufIn.Load(blockSizeOffset);
            decompOffset += BufIn.Load(offset + 0x0C);
            offset += n & 0xFFFF;
            j++;
            blockSizeOffset += 2;
            break;
        } else {
            const uint32_t n = BufIn.Load(blockSizeOffset);
            decompOffset += BufIn.Load(offset + 0x0C);
            offset += n & 0xFFFF;
            decompOffset += BufIn.Load(offset + 0x0C);
            offset += n >> 16;
            j += 2;
            blockSizeOffset += 4;
        }
    }
}

[numthreads(NUM_THREADS, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID)
{
    const uint32_t dataOffset = BufIn.Load(0);
    const uint32_t lodBlockCount = BufIn.Load(0x14);
   
    if (dtid.x == 0) {
        for (uint32_t i = 0; i < TEX_HEADER_SIZE; i += 0x10)
            BufOut.Store4(i, BufIn.Load4(dataOffset + i));
    }

    uint32_t totalBlockCount = 0
        + BufIn.Load(0x18 + (0x14 * (lodBlockCount - 1)) + 0x0C) // last subBlockIndex
        + BufIn.Load(0x18 + (0x14 * (lodBlockCount - 1)) + 0x10); // last subBlockCount
    
    uint32_t blockIndex = totalBlockCount * dtid.x / NUM_THREADS;
    const uint32_t blockIndexTo = totalBlockCount * (dtid.x + 1) / NUM_THREADS;

    uint32_t decompOffset = TEX_HEADER_SIZE;
    for (uint32_t lodBlockIndex = 0; lodBlockIndex < lodBlockCount && blockIndex < blockIndexTo; lodBlockIndex++) {
        const uint32_t compressedOffset = BufIn.Load(0x18 + (0x14 * lodBlockIndex) + 0x00);
        const uint32_t subBlockIndex = BufIn.Load(0x18 + (0x14 * lodBlockIndex) + 0x0C);
        const uint32_t subBlockCount = BufIn.Load(0x18 + (0x14 * lodBlockIndex) + 0x10);
        if (blockIndex < subBlockIndex) {
            decompOffset += BufIn.Load(0x18 + (0x14 * lodBlockIndex) + 0x08);
            continue;
        }
        if (blockIndex >= subBlockIndex + subBlockCount || blockIndex >= blockIndexTo)
            break;

        uint32_t offset = dataOffset + compressedOffset;
        uint32_t blockSizeOffset = 0x18 + (0x14 * lodBlockCount) + (0x02 * subBlockIndex);
        uint32_t decompOffsetCopy = decompOffset;
        FindOffsets(blockSizeOffset, subBlockIndex, blockIndex, decompOffsetCopy, offset);
        for (; blockIndex < blockIndexTo && blockIndex < subBlockIndex + subBlockCount;)
            DecompressBlock(blockIndex, blockSizeOffset, decompOffsetCopy, offset);
    }
}

/*
[Header]
0x00    align(sizeof(Header) + sizeof(LodBlock[]) + sizeof(SubBlockSize=ushort[]), 128)
0x04    Type = 4
0x08    RawFileSize
0x0C    -
0x10    -
0x14    (LodBlock[]).Length

[LodBlock]
0x00    CompressedOffset
0x04    CompressedSize
0x08    DecompressedSize
0x0C    BlockOffset
0x10    BlockCount

*/
