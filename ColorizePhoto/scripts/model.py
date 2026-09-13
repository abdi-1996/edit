import requests, hashlib, json, pathlib
import coremltools as ct
repo='zimageapp/CoreML-Models'
name='realesrgan512.mlmodel'
meta=requests.get(f'https://huggingface.co/api/models/{repo}?blobs=true',timeout=60);meta.raise_for_status();meta=meta.json()
sha=meta['sha']
entry=next(x for x in meta['siblings'] if x['rfilename']==name)
expected=entry['lfs']['sha256']
r=requests.get(f'https://huggingface.co/{repo}/resolve/{sha}/{name}',timeout=300);r.raise_for_status()
assert hashlib.sha256(r.content).hexdigest()==expected,'Model checksum mismatch'
p=pathlib.Path('PhotoApp/RealESRGAN.mlmodel');p.write_bytes(r.content)
spec=ct.utils.load_spec(str(p))
report={'repo':repo,'revision':sha,'sha256':expected,'bytes':len(r.content),'input':str(spec.description.input),'output':str(spec.description.output)}
pathlib.Path('model-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
assert any(x.type.HasField('imageType') for x in spec.description.input),'Model must accept image input'
# Include the upstream BSD license alongside the packaged model.
u='https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE'
license=requests.get(u,timeout=60);license.raise_for_status();pathlib.Path('PhotoApp/RealESRGAN-LICENSE.txt').write_text(license.text)
