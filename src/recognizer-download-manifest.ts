/** Immutable upstream revisions. Hashes from HF LFS metadata and the retained
 * benchmark download manifest (config.json, 244093 bytes); never infer a hash. */
export interface RecognizerDownloadFile { name: string; url: string; bytes: number; sha256: string }
const hf = (repo: string, revision: string, name: string, bytes: number, sha256: string): RecognizerDownloadFile =>
  ({ name, url: `https://huggingface.co/${repo}/resolve/${revision}/${name}`, bytes, sha256 });
export const RECOGNIZER_DOWNLOADS = {
  whisper: [hf("ggerganov/whisper.cpp", "5359861c739e955e79d9a303bcbc70fb988958b1", "ggml-large-v3-turbo.bin", 1624555275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")],
  parakeet: [
    hf("mlx-community/parakeet-tdt-0.6b-v3", "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", "config.json", 244093, "f320f1292511f34ec47f513755fe20fd01dbfc09a925d42730e66059a6e1ef4c"),
    hf("mlx-community/parakeet-tdt-0.6b-v3", "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", "model.safetensors", 2508288736, "05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592"),
    hf("mlx-community/parakeet-tdt-0.6b-v3", "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", "tokenizer.model", 360916, "eacec2b0a77f336d4a2ca4a25a7047575d3c2b74de47e997f4c205126ed3135e"),
  ],
};
