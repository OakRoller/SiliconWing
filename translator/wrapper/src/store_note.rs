//! shmirror (plugin NVMTL_SHMIRROR, notes item 66): every store, atomic and memory copy through a PhysicalStorageBuffer
//! pointer is followed by a call to a generated function `note(addr, bytes)` that marks the 4-byte chunks it wrote in
//! the dirty bitmap of the twinned (VRAM-mirrored Shared) range the address falls in, so the plugin can copy exactly
//! those chunks back to system memory before the CPU looks.
//!
//! The table's GPU address is a 64-bit specialization constant (SpecId [`SPEC_ID`], default 0 = do nothing), so the
//! instrumented SPIR-V is the same in every process and the pipeline supplies the address. Table (VRAM, at T):
//!   T + 0      u32 l1[1024]: for VA bits 30..39, the byte offset from T of that gigabyte's level-2 page, 0 = none
//!   T + 4096   entries, 64 bytes each: u64 base, u64 length, u64 bitmap address, u64 summary address, u64 shadow address
//!   level-2 page: u32 slot[16384], one per 64 KB of VA (the NVRM allocator's granule, so a slot is never shared):
//!              entry index + 1, 0 = not twinned
//! Lookups never move: adding a range writes new slots only, so the GPU may read while the CPU adds.
//! Bitmap: one bit per 4 bytes, u32 words (chunk c = bit c&31 of word c>>5). Summary: one bit per 4096 words (512 KB),
//! so the copy-back kernel skips the untouched parts.
//!
//! A call instead of inline code: the call site needs no new blocks, so structured control flow is untouched wherever
//! the store sits (loop headers included); NVK inlines it.

use rspirv::{binary::Assemble, dr::{Instruction, Module, Operand}, spirv::*};
use std::collections::HashMap;

pub const SPEC_ID: u32 = 0x4E56_5301;

fn id(o: &Operand) -> Option<u32> { if let Operand::IdRef(v) = o { Some(*v) } else { None } }
fn lit(o: &Operand) -> Option<u32> { if let Operand::LiteralBit32(v) = o { Some(*v) } else { None } }

#[derive(Default, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Report { pub sites: u32, pub unknown_size: u32 }

struct Ids { next: u32 }
impl Ids { fn take(&mut self) -> u32 { let v = self.next; self.next += 1; v } }

/// Byte size of a type under the explicit layout PhysicalStorageBuffer requires (Offset / ArrayStride decorations).
fn byte_size(ty: u32, defs: &HashMap<u32, Instruction>, consts: &HashMap<u32, u64>, strides: &HashMap<u32, u32>,
             offsets: &HashMap<(u32, u32), u32>, depth: usize) -> Option<u64> {
    if depth > 32 { return None; }
    let t = defs.get(&ty)?;
    match t.class.opcode {
        Op::TypeInt | Op::TypeFloat => Some(lit(t.operands.first()?)? as u64 / 8),
        Op::TypeBool => Some(4),
        Op::TypePointer => Some(8),
        Op::TypeVector | Op::TypeMatrix => {
            let n = lit(t.operands.get(1)?)? as u64;
            Some(n * byte_size(id(t.operands.first()?)?, defs, consts, strides, offsets, depth + 1)?)
        }
        Op::TypeArray => {
            let n = *consts.get(&id(t.operands.get(1)?)?)?;
            let stride = match strides.get(&ty) { Some(s) => *s as u64, None => byte_size(id(t.operands.first()?)?, defs, consts, strides, offsets, depth + 1)? };
            Some(n * stride)
        }
        Op::TypeStruct => {
            let mut end = 0u64;
            for (m, o) in t.operands.iter().enumerate() {
                let off = *offsets.get(&(ty, m as u32))? as u64;
                end = end.max(off + byte_size(id(o)?, defs, consts, strides, offsets, depth + 1)?);
            }
            Some(end)
        }
        _ => None,
    }
}

/// Instrument `bytes`; returns the module unchanged (same bytes) when it stores nothing through a PSB pointer.
pub fn instrument(bytes: &[u8]) -> Result<(Vec<u8>, Report), String> {
    let mut m: Module = rspirv::dr::load_bytes(bytes).map_err(|e| e.to_string())?;
    // already instrumented (the note function's own atomic must never get a note: recursion)
    if m.annotations.iter().any(|a| a.operands.get(1) == Some(&Operand::Decoration(Decoration::SpecId)) && a.operands.get(2) == Some(&Operand::LiteralBit32(SPEC_ID))) {
        return Ok((bytes.to_vec(), Report::default()));
    }
    let defs: HashMap<u32, Instruction> = m.types_global_values.iter().filter_map(|i| Some((i.result_id?, i.clone()))).collect();
    let mut value_types = HashMap::new();
    for i in m.all_inst_iter() { if let (Some(n), Some(t)) = (i.result_id, i.result_type) { value_types.insert(n, t); } }
    let psb_pointee = |ptr: u32| -> Option<u32> {
        let t = defs.get(value_types.get(&ptr)?)?;
        (t.class.opcode == Op::TypePointer && t.operands.first() == Some(&Operand::StorageClass(StorageClass::PhysicalStorageBuffer)))
            .then(|| id(t.operands.get(1)?)).flatten()
    };
    // sites first; nothing to do -> the same bytes
    let is_store_like = |op: Op| matches!(op, Op::Store | Op::AtomicStore | Op::AtomicExchange | Op::AtomicCompareExchange
        | Op::AtomicIIncrement | Op::AtomicIDecrement | Op::AtomicIAdd | Op::AtomicISub | Op::AtomicSMin | Op::AtomicUMin
        | Op::AtomicSMax | Op::AtomicUMax | Op::AtomicAnd | Op::AtomicOr | Op::AtomicXor | Op::AtomicFAddEXT | Op::AtomicFMinEXT
        | Op::AtomicFMaxEXT | Op::CopyMemory | Op::CopyMemorySized);
    let any = m.functions.iter().flat_map(|f| f.blocks.iter()).flat_map(|b| b.instructions.iter())
        .any(|i| is_store_like(i.class.opcode) && i.operands.first().and_then(id).and_then(&psb_pointee).is_some());
    if !any { return Ok((bytes.to_vec(), Report::default())); }

    let consts: HashMap<u32, u64> = m.types_global_values.iter().filter(|i| i.class.opcode == Op::Constant).filter_map(|i| {
        let v = match i.operands.as_slice() {
            [Operand::LiteralBit32(a)] => *a as u64,
            [Operand::LiteralBit64(a)] => *a,
            _ => return None,
        };
        Some((i.result_id?, v))
    }).collect();
    let mut strides = HashMap::new(); let mut offsets = HashMap::new();
    for a in &m.annotations {
        match (a.class.opcode, a.operands.as_slice()) {
            (Op::Decorate, [Operand::IdRef(t), Operand::Decoration(Decoration::ArrayStride), Operand::LiteralBit32(s)]) => { strides.insert(*t, *s); }
            (Op::MemberDecorate, [Operand::IdRef(t), Operand::LiteralBit32(mm), Operand::Decoration(Decoration::Offset), Operand::LiteralBit32(o)]) => { offsets.insert((*t, *mm), *o); }
            _ => {}
        }
    }
    let mut ids = Ids { next: m.header.as_ref().map(|h| h.bound).unwrap_or(1) };

    // types: reuse an existing declaration where SPIR-V forbids a duplicate, declare otherwise
    let find_ty = |m: &Module, op: Op, ops: &[Operand]| m.types_global_values.iter().find(|i| i.class.opcode == op && i.operands == ops).and_then(|i| i.result_id);
    let decl = |m: &mut Module, ids: &mut Ids, op: Op, ops: Vec<Operand>| -> u32 {
        if let Some(t) = find_ty(m, op, &ops) { return t; }
        let r = ids.take(); m.types_global_values.push(Instruction::new(op, None, Some(r), ops)); r
    };
    let t_void = decl(&mut m, &mut ids, Op::TypeVoid, vec![]);
    let t_bool = decl(&mut m, &mut ids, Op::TypeBool, vec![]);
    let t_u32 = decl(&mut m, &mut ids, Op::TypeInt, vec![Operand::LiteralBit32(32), Operand::LiteralBit32(0)]);
    let t_u64 = decl(&mut m, &mut ids, Op::TypeInt, vec![Operand::LiteralBit32(64), Operand::LiteralBit32(0)]);
    let p_u32 = decl(&mut m, &mut ids, Op::TypePointer, vec![Operand::StorageClass(StorageClass::PhysicalStorageBuffer), Operand::IdRef(t_u32)]);
    let p_u64 = decl(&mut m, &mut ids, Op::TypePointer, vec![Operand::StorageClass(StorageClass::PhysicalStorageBuffer), Operand::IdRef(t_u64)]);
    let fn_ty = decl(&mut m, &mut ids, Op::TypeFunction, vec![Operand::IdRef(t_void), Operand::IdRef(t_u64), Operand::IdRef(t_u32)]);
    let k32 = |m: &mut Module, ids: &mut Ids, v: u32| { let r = ids.take(); m.types_global_values.push(Instruction::new(Op::Constant, Some(t_u32), Some(r), vec![Operand::LiteralBit32(v)])); r };
    let c0 = k32(&mut m, &mut ids, 0); let c1 = k32(&mut m, &mut ids, 1);
    let c5 = k32(&mut m, &mut ids, 5); let c31 = k32(&mut m, &mut ids, 31);
    let scope_dev = c1; let sem_relaxed = c0;
    let k64 = |m: &mut Module, ids: &mut Ids, v: u64| { let r = ids.take(); m.types_global_values.push(Instruction::new(Op::Constant, Some(t_u64), Some(r), vec![Operand::LiteralBit64(v)])); r };
    let q0 = k64(&mut m, &mut ids, 0); let q1 = k64(&mut m, &mut ids, 1); let q4 = k64(&mut m, &mut ids, 4); let q8 = k64(&mut m, &mut ids, 8);
    let q16 = k64(&mut m, &mut ids, 16); let q24 = k64(&mut m, &mut ids, 24);
    let spec = ids.take();
    m.types_global_values.push(Instruction::new(Op::SpecConstant, Some(t_u64), Some(spec), vec![Operand::LiteralBit64(0)]));
    m.annotations.push(Instruction::new(Op::Decorate, None, None, vec![Operand::IdRef(spec), Operand::Decoration(Decoration::SpecId), Operand::LiteralBit32(SPEC_ID)]));
    for cap in [Capability::Int64, Capability::PhysicalStorageBufferAddresses] {
        if !m.capabilities.iter().any(|c| c.operands.first() == Some(&Operand::Capability(cap))) {
            m.capabilities.push(Instruction::new(Op::Capability, None, None, vec![Operand::Capability(cap)]));
        }
    }

    // the note function
    let f_note = ids.take(); let a_addr = ids.take(); let a_size = ids.take();
    let mut body: Vec<rspirv::dr::Block> = Vec::new();
    let blk = |label: u32, insts: Vec<Instruction>| rspirv::dr::Block { label: Some(Instruction::new(Op::Label, None, Some(label), vec![])), instructions: insts };
    let i = |op: Op, ty: Option<u32>, r: Option<u32>, ops: Vec<Operand>| Instruction::new(op, ty, r, ops);
    let r = |v: u32| Operand::IdRef(v);
    let load = |dst: u32, ty: u32, ptr: u32, align: u32| Instruction::new(Op::Load, Some(ty), Some(dst), vec![Operand::IdRef(ptr), Operand::MemoryAccess(MemoryAccess::ALIGNED), Operand::LiteralBit32(align)]);
    let sel = |merge: u32, cond: u32, then: u32| vec![
        Instruction::new(Op::SelectionMerge, None, None, vec![Operand::IdRef(merge), Operand::SelectionControl(SelectionControl::NONE)]),
        Instruction::new(Op::BranchConditional, None, None, vec![Operand::IdRef(cond), Operand::IdRef(then), Operand::IdRef(merge)])];
    let q30 = k64(&mut m, &mut ids, 30); let q40 = k64(&mut m, &mut ids, 40); let q16k = k64(&mut m, &mut ids, 16383);
    let q4096 = k64(&mut m, &mut ids, 4096); let q64 = k64(&mut m, &mut ids, 64);
    let (l0, l1, l2, l3, l4, mh, mb, mbody, mc, mm, e4, e3, e2, e1) =
        (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(),
         ids.take(), ids.take(), ids.take(), ids.take());
    // L0: a table, and an address below 2^40
    let (ok, top, low, go0) = (ids.take(), ids.take(), ids.take(), ids.take());
    let mut b = vec![
        i(Op::INotEqual, Some(t_bool), Some(ok), vec![r(spec), r(q0)]),
        i(Op::ShiftRightLogical, Some(t_u64), Some(top), vec![r(a_addr), r(q40)]),
        i(Op::IEqual, Some(t_bool), Some(low), vec![r(top), r(q0)]),
        i(Op::LogicalAnd, Some(t_bool), Some(go0), vec![r(ok), r(low)]),
    ]; b.extend(sel(e1, go0, l1)); body.push(blk(l0, b));
    // L1: level 1
    let (gi, go, ga, gp, l1v, has1) = (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take());
    let mut b = vec![
        i(Op::ShiftRightLogical, Some(t_u64), Some(gi), vec![r(a_addr), r(q30)]), i(Op::IMul, Some(t_u64), Some(go), vec![r(gi), r(q4)]),
        i(Op::IAdd, Some(t_u64), Some(ga), vec![r(spec), r(go)]), i(Op::ConvertUToPtr, Some(p_u32), Some(gp), vec![r(ga)]), load(l1v, t_u32, gp, 4),
        i(Op::INotEqual, Some(t_bool), Some(has1), vec![r(l1v), r(c0)]),
    ]; b.extend(sel(e2, has1, l2)); body.push(blk(l1, b));
    // L2: level 2 slot
    let (l1q, s0, si, so, sa0, sa, sp, ev, has2) = (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take());
    let mut b = vec![
        i(Op::UConvert, Some(t_u64), Some(l1q), vec![r(l1v)]),
        i(Op::ShiftRightLogical, Some(t_u64), Some(s0), vec![r(a_addr), r(q16)]), i(Op::BitwiseAnd, Some(t_u64), Some(si), vec![r(s0), r(q16k)]),
        i(Op::IMul, Some(t_u64), Some(so), vec![r(si), r(q4)]), i(Op::IAdd, Some(t_u64), Some(sa0), vec![r(spec), r(l1q)]),
        i(Op::IAdd, Some(t_u64), Some(sa), vec![r(sa0), r(so)]), i(Op::ConvertUToPtr, Some(p_u32), Some(sp), vec![r(sa)]), load(ev, t_u32, sp, 4),
        i(Op::INotEqual, Some(t_bool), Some(has2), vec![r(ev), r(c0)]),
    ]; b.extend(sel(e3, has2, l3)); body.push(blk(l2, b));
    // L3: the entry
    let (ei, ei64, eo, eb0, eb, pb, b0, el, pl, len, em, pm, bm, es, ps_, sm, rel, inside) =
        (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(),
         ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take());
    let mut b = vec![
        i(Op::ISub, Some(t_u32), Some(ei), vec![r(ev), r(c1)]), i(Op::UConvert, Some(t_u64), Some(ei64), vec![r(ei)]),
        i(Op::IMul, Some(t_u64), Some(eo), vec![r(ei64), r(q64)]), i(Op::IAdd, Some(t_u64), Some(eb0), vec![r(spec), r(q4096)]),
        i(Op::IAdd, Some(t_u64), Some(eb), vec![r(eb0), r(eo)]), i(Op::ConvertUToPtr, Some(p_u64), Some(pb), vec![r(eb)]), load(b0, t_u64, pb, 8),
        i(Op::IAdd, Some(t_u64), Some(el), vec![r(eb), r(q8)]), i(Op::ConvertUToPtr, Some(p_u64), Some(pl), vec![r(el)]), load(len, t_u64, pl, 8),
        i(Op::IAdd, Some(t_u64), Some(em), vec![r(eb), r(q16)]), i(Op::ConvertUToPtr, Some(p_u64), Some(pm), vec![r(em)]), load(bm, t_u64, pm, 8),
        i(Op::IAdd, Some(t_u64), Some(es), vec![r(eb), r(q24)]), i(Op::ConvertUToPtr, Some(p_u64), Some(ps_), vec![r(es)]), load(sm, t_u64, ps_, 8),
        i(Op::ISub, Some(t_u64), Some(rel), vec![r(a_addr), r(b0)]), i(Op::ULessThan, Some(t_bool), Some(inside), vec![r(rel), r(len)]),
    ]; b.extend(sel(e4, inside, l4)); body.push(blk(l3, b));
    // L4: 4-byte chunks rel>>2 .. min(rel+bytes-1, len-1)>>2, one bitmap word (32 chunks, 128 bytes) per iteration: the
    // copy-back copies exactly the words the GPU wrote, so CPU writes to the other bytes of a 16-byte block survive
    let (sz64, sz64m1, last0, lenm1, toolong, last, cfirst64, clast64, cfirst, clast, wfirst, wlast) =
        (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take());
    let q2 = k64(&mut m, &mut ids, 2); let c12 = k32(&mut m, &mut ids, 12); let cff = k32(&mut m, &mut ids, 0xffff_ffff);
    body.push(blk(l4, vec![
        i(Op::UConvert, Some(t_u64), Some(sz64), vec![r(a_size)]), i(Op::ISub, Some(t_u64), Some(sz64m1), vec![r(sz64), r(q1)]),
        i(Op::IAdd, Some(t_u64), Some(last0), vec![r(rel), r(sz64m1)]), i(Op::ISub, Some(t_u64), Some(lenm1), vec![r(len), r(q1)]),
        i(Op::UGreaterThan, Some(t_bool), Some(toolong), vec![r(last0), r(lenm1)]), i(Op::Select, Some(t_u64), Some(last), vec![r(toolong), r(lenm1), r(last0)]),
        i(Op::ShiftRightLogical, Some(t_u64), Some(cfirst64), vec![r(rel), r(q2)]), i(Op::ShiftRightLogical, Some(t_u64), Some(clast64), vec![r(last), r(q2)]),
        i(Op::UConvert, Some(t_u32), Some(cfirst), vec![r(cfirst64)]), i(Op::UConvert, Some(t_u32), Some(clast), vec![r(clast64)]),
        i(Op::ShiftRightLogical, Some(t_u32), Some(wfirst), vec![r(cfirst), r(c5)]), i(Op::ShiftRightLogical, Some(t_u32), Some(wlast), vec![r(clast), r(c5)]),
        i(Op::Branch, None, None, vec![r(mh)]),
    ]));
    let (w, wn) = (ids.take(), ids.take());
    body.push(blk(mh, vec![
        i(Op::Phi, Some(t_u32), Some(w), vec![r(wfirst), r(l4), r(wn), r(mc)]),
        i(Op::LoopMerge, None, None, vec![r(mm), r(mc), Operand::LoopControl(LoopControl::NONE)]),
        i(Op::Branch, None, None, vec![r(mb)]),
    ]));
    let more = ids.take();
    body.push(blk(mb, vec![
        i(Op::ULessThanEqual, Some(t_bool), Some(more), vec![r(w), r(wlast)]),
        i(Op::BranchConditional, None, None, vec![r(more), r(mbody), r(mm)]),
    ]));
    let (isf, isl, lo0, lo, hi0, hi, his, mhi, mlo, mask, wi64, wo, wa, pw, old, g, gw, gw64, gwo, gwa, gpw, gbn, gbit, gold) =
        (ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(),
         ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(), ids.take(),
         ids.take(), ids.take(), ids.take(), ids.take());
    body.push(blk(mbody, vec![
        // bits lo..hi of word w: lo = cfirst&31 in the first word else 0, hi = clast&31 in the last word else 31
        i(Op::IEqual, Some(t_bool), Some(isf), vec![r(w), r(wfirst)]), i(Op::IEqual, Some(t_bool), Some(isl), vec![r(w), r(wlast)]),
        i(Op::BitwiseAnd, Some(t_u32), Some(lo0), vec![r(cfirst), r(c31)]), i(Op::Select, Some(t_u32), Some(lo), vec![r(isf), r(lo0), r(c0)]),
        i(Op::BitwiseAnd, Some(t_u32), Some(hi0), vec![r(clast), r(c31)]), i(Op::Select, Some(t_u32), Some(hi), vec![r(isl), r(hi0), r(c31)]),
        i(Op::ISub, Some(t_u32), Some(his), vec![r(c31), r(hi)]), i(Op::ShiftRightLogical, Some(t_u32), Some(mhi), vec![r(cff), r(his)]),
        i(Op::ShiftLeftLogical, Some(t_u32), Some(mlo), vec![r(cff), r(lo)]), i(Op::BitwiseAnd, Some(t_u32), Some(mask), vec![r(mhi), r(mlo)]),
        i(Op::UConvert, Some(t_u64), Some(wi64), vec![r(w)]), i(Op::IMul, Some(t_u64), Some(wo), vec![r(wi64), r(q4)]),
        i(Op::IAdd, Some(t_u64), Some(wa), vec![r(bm), r(wo)]), i(Op::ConvertUToPtr, Some(p_u32), Some(pw), vec![r(wa)]),
        i(Op::AtomicOr, Some(t_u32), Some(old), vec![r(pw), r(scope_dev), r(sem_relaxed), r(mask)]),
        // summary: granule g = w >> 12 (4096 words = 512 KB), bit g&31 of word g>>5
        i(Op::ShiftRightLogical, Some(t_u32), Some(g), vec![r(w), r(c12)]), i(Op::ShiftRightLogical, Some(t_u32), Some(gw), vec![r(g), r(c5)]),
        i(Op::UConvert, Some(t_u64), Some(gw64), vec![r(gw)]), i(Op::IMul, Some(t_u64), Some(gwo), vec![r(gw64), r(q4)]),
        i(Op::IAdd, Some(t_u64), Some(gwa), vec![r(sm), r(gwo)]), i(Op::ConvertUToPtr, Some(p_u32), Some(gpw), vec![r(gwa)]),
        i(Op::BitwiseAnd, Some(t_u32), Some(gbn), vec![r(g), r(c31)]), i(Op::ShiftLeftLogical, Some(t_u32), Some(gbit), vec![r(c1), r(gbn)]),
        i(Op::AtomicOr, Some(t_u32), Some(gold), vec![r(gpw), r(scope_dev), r(sem_relaxed), r(gbit)]),
        i(Op::IAdd, Some(t_u32), Some(wn), vec![r(w), r(c1)]),
        i(Op::Branch, None, None, vec![r(mc)]),
    ]));
    body.push(blk(mc, vec![i(Op::Branch, None, None, vec![r(mh)])]));
    body.push(blk(mm, vec![i(Op::Branch, None, None, vec![r(e4)])]));
    body.push(blk(e4, vec![i(Op::Branch, None, None, vec![r(e3)])]));
    body.push(blk(e3, vec![i(Op::Branch, None, None, vec![r(e2)])]));
    body.push(blk(e2, vec![i(Op::Branch, None, None, vec![r(e1)])]));
    body.push(blk(e1, vec![i(Op::Return, None, None, vec![])]));
    let note = rspirv::dr::Function {
        def: Some(Instruction::new(Op::Function, Some(t_void), Some(f_note), vec![Operand::FunctionControl(FunctionControl::NONE), Operand::IdRef(fn_ty)])),
        end: Some(Instruction::new(Op::FunctionEnd, None, None, vec![])),
        parameters: vec![Instruction::new(Op::FunctionParameter, Some(t_u64), Some(a_addr), vec![]),
                         Instruction::new(Op::FunctionParameter, Some(t_u32), Some(a_size), vec![])],
        blocks: body,
    };

    // call sites
    let mut rep = Report::default();
    let mut size_consts: HashMap<u64, u32> = HashMap::new();
    let mut pending_consts: Vec<Instruction> = Vec::new();
    for f in &mut m.functions {
        for b in &mut f.blocks {
            let mut out = Vec::with_capacity(b.instructions.len());
            for inst in std::mem::take(&mut b.instructions) {
                let op = inst.class.opcode;
                let ptr = if is_store_like(op) { inst.operands.first().and_then(id) } else { None };
                let pointee = ptr.and_then(&psb_pointee);
                let size = match (op, pointee) {
                    (_, None) => None,
                    (Op::CopyMemorySized, Some(_)) => inst.operands.get(2).and_then(id).and_then(|s| consts.get(&s).copied()).or(Some(256)),
                    (_, Some(t)) => byte_size(t, &defs, &consts, &strides, &offsets, 0).or_else(|| { rep.unknown_size += 1; Some(16) }),
                };
                out.push(inst);
                if let (Some(p), Some(sz)) = (ptr, size) {
                    let sz = sz.clamp(1, u32::MAX as u64);
                    let kc = *size_consts.entry(sz).or_insert_with(|| {
                        let k = ids.take();
                        pending_consts.push(Instruction::new(Op::Constant, Some(t_u32), Some(k), vec![Operand::LiteralBit32(sz as u32)]));
                        k
                    });
                    let a = ids.take(); let call = ids.take();
                    out.push(Instruction::new(Op::ConvertPtrToU, Some(t_u64), Some(a), vec![Operand::IdRef(p)]));
                    out.push(Instruction::new(Op::FunctionCall, Some(t_void), Some(call), vec![Operand::IdRef(f_note), Operand::IdRef(a), Operand::IdRef(kc)]));
                    rep.sites += 1;
                }
            }
            b.instructions = out;
        }
    }
    m.types_global_values.extend(pending_consts);
    m.functions.push(note);
    if let Some(h) = m.header.as_mut() { h.bound = ids.next; }
    Ok((m.assemble().iter().flat_map(|w| w.to_le_bytes()).collect(), rep))
}

#[cfg(test)]
mod tests {
    use super::*;
    const KERNEL: &str = r#"
OpCapability Shader
OpCapability Int64
OpCapability PhysicalStorageBufferAddresses
OpExtension "SPV_KHR_physical_storage_buffer"
OpMemoryModel PhysicalStorageBuffer64 GLSL450
OpEntryPoint GLCompute %main "main" %gid
OpExecutionMode %main LocalSize 64 1 1
OpDecorate %gid BuiltIn GlobalInvocationId
OpDecorate %arr ArrayStride 16
OpMemberDecorate %st 0 Offset 0
OpMemberDecorate %st 1 Offset 16
%void = OpTypeVoid
%uint = OpTypeInt 32 0
%ulong = OpTypeInt 64 0
%float = OpTypeFloat 32
%v4 = OpTypeVector %float 4
%v3 = OpTypeVector %uint 3
%c4 = OpConstant %uint 4
%arr = OpTypeArray %v4 %c4
%st = OpTypeStruct %v4 %arr
%pin = OpTypePointer Input %v3
%gid = OpVariable %pin Input
%pu = OpTypePointer PhysicalStorageBuffer %uint
%pv = OpTypePointer PhysicalStorageBuffer %v4
%ps = OpTypePointer PhysicalStorageBuffer %st
%base = OpConstant %ulong 4096
%one = OpConstant %uint 1
%dev = OpConstant %uint 1
%sem = OpConstant %uint 0
%fz = OpConstant %float 0
%vz = OpConstantComposite %v4 %fz %fz %fz %fz
%fn = OpTypeFunction %void
%main = OpFunction %void None %fn
%label = OpLabel
%g3 = OpLoad %v3 %gid
%g = OpCompositeExtract %uint %g3 0
%pw = OpConvertUToPtr %pu %base
OpStore %pw %g Aligned 4
%old = OpAtomicIAdd %uint %pw %dev %sem %one
%pv4 = OpConvertUToPtr %pv %base
OpStore %pv4 %vz Aligned 16
%pst = OpConvertUToPtr %ps %base
%x = OpLoad %st %pst Aligned 16
OpStore %pst %x Aligned 16
OpBranch %loop
%loop = OpLabel
OpLoopMerge %done %cont None
OpBranch %body
%body = OpLabel
OpStore %pw %one Aligned 4
OpBranch %cont
%cont = OpLabel
OpBranchConditional %fz_false %loop %done
%done = OpLabel
OpReturn
OpFunctionEnd
"#;
    fn asm(text: &str) -> Vec<u8> {
        let t = text.replace("%fz_false", "%false").replace("%void = OpTypeVoid", "%void = OpTypeVoid\n%bool = OpTypeBool\n%false = OpConstantFalse %bool");
        use spirv_tools::assembler::Assembler;
        spirv_tools::assembler::create(Some(spirv_tools::TargetEnv::Vulkan_1_2)).assemble(&t, Default::default()).unwrap().as_bytes().to_vec()
    }
    fn validate(b: &[u8]) {
        use spirv_tools::val::Validator;
        let w: Vec<u32> = b.chunks_exact(4).map(|w| u32::from_le_bytes(w.try_into().unwrap())).collect();
        spirv_tools::val::create(Some(spirv_tools::TargetEnv::Vulkan_1_2)).validate(&w, None).unwrap();
    }
    #[test] fn every_psb_store_atomic_and_struct_store_gets_a_note_and_the_module_validates() {
        let src = asm(KERNEL);
        validate(&src);
        let (out, rep) = instrument(&src).unwrap();
        assert_eq!(rep, Report { sites: 5, unknown_size: 0 }, "u32 store, atomic, v4 store, 80-byte struct store, store in a loop body");
        validate(&out);
        let text = rspirv::dr::load_bytes(&out).unwrap();
        let calls = text.all_inst_iter().filter(|i| i.class.opcode == Op::FunctionCall).count();
        assert_eq!(calls, 5);
        assert!(text.annotations.iter().any(|a| a.operands.get(2) == Some(&Operand::LiteralBit32(SPEC_ID))));
        let sizes: Vec<u32> = text.types_global_values.iter().filter(|i| i.class.opcode == Op::Constant)
            .filter_map(|i| lit(i.operands.first()?)).collect();
        assert!(sizes.contains(&80), "the struct store is 16 + 4 x 16 bytes: {sizes:?}");
    }
    #[test] fn a_module_without_psb_stores_is_returned_as_is() {
        let src = asm(&KERNEL.replace("OpStore %pw %g Aligned 4\n", "").replace("%old = OpAtomicIAdd %uint %pw %dev %sem %one\n", "")
            .replace("OpStore %pv4 %vz Aligned 16\n", "").replace("OpStore %pst %x Aligned 16\n", "").replace("OpStore %pw %one Aligned 4\n", ""));
        let (out, rep) = instrument(&src).unwrap();
        assert_eq!((rep.sites, out == src), (0, true));
    }
    #[test] fn instrumenting_twice_changes_nothing() {
        let (once, _) = instrument(&asm(KERNEL)).unwrap();
        let (twice, rep) = instrument(&once).unwrap();
        assert_eq!((rep.sites, twice == once), (0, true), "the note function's atomic must not get a note (recursion)");
    }
}
