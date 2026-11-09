// Replays a pipeline link the plugin dumped (NVMTL_LINK_DUMP=<dir>): <dir>/<kernel>.kernel.ll is linked against every
// <dir>/mod.<symbol>.ll as a runtime-table candidate (what nvmtl_link_runtime does), then translated like
// nvmtl_translate_fc without constants. Usage: link_rt <dir> <kernel> [out.spv]
use std::path::Path;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 { eprintln!("usage: link_rt <dumpdir> <kernel> [out.spv]"); std::process::exit(2); }
    let dir = Path::new(&a[1]);
    let ll = std::fs::read_to_string(dir.join(format!("{}.kernel.ll", a[2]))).expect("kernel.ll");
    let mut cands = Vec::new();
    let mut names: Vec<_> = std::fs::read_dir(dir).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("mod.") && n.ends_with(".ll")).collect();
    names.sort();
    for n in names {
        let sym = n["mod.".len()..n.len() - 3].to_string();
        cands.push((sym, std::fs::read_to_string(dir.join(&n)).unwrap()));
    }
    eprintln!("{} candidate(s)", cands.len());
    let linked = match metal2vulkan::specialize_runtime_table_module(&ll, metal2vulkan::passes::Stage::Kernel, vec![], &cands) {
        Ok(v) => v, Err(e) => { eprintln!("LINK FAILED: {e}"); std::process::exit(1); } };
    std::fs::write(dir.join(format!("{}.relinked.ll", a[2])), &linked).unwrap();
    eprintln!("linked: {} B -> {}.relinked.ll", linked.len(), a[2]);
    let spec = match metal2vulkan::specialize_air_function_constants(&linked, &[]) { Ok(v) => v, Err(e) => { eprintln!("FC FAILED: {e}"); std::process::exit(1); } };
    let spec = match metal2vulkan::linked_functions::specialize_visible_function_references(spec.as_ref(), &metal2vulkan::linked_functions::LinkedFunctionLinkage::default()) {
        Ok(v) => v, Err(e) => { eprintln!("VREF FAILED: {e}"); std::process::exit(1); } };
    let translate = |ll: &str| metal2vulkan::translate_native_no_retry_constructed_with_options(ll, metal2vulkan::passes::Stage::Kernel, metal2vulkan::passes::TransformOptions::default());
    // the plugin's wrapper retries a sampler read out of an argument buffer with the sampler heap (translate_with_pointer_retry)
    let result = match translate(spec.as_str()) {
        Err(e) if e.contains("sampler operand") => {
            eprintln!("first attempt: {e}\n-> retry with argument-buffer samplers from the sampler heap");
            metal2vulkan::with_argument_buffer_samplers(|| translate(spec.as_str())).map_err(|e2| format!("{e}; retry: {e2}"))
        }
        other => other,
    };
    match result {
        Ok(spv) => { eprintln!("TRANSLATED: {} B of SPIR-V", spv.len()); if a.len() > 3 { std::fs::write(&a[3], &spv).unwrap(); } }
        Err(e) => { eprintln!("TRANSLATE FAILED: {e}"); std::process::exit(1); }
    }
}
