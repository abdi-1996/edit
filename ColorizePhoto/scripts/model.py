import requests, hashlib, json, pathlib
import coremltools as ct
repo='zimageapp/CoreML-Models'
name='realesrgan512.mlmodel'
sha='5d2df01c0895f386793ab3ecf40264d05798e23d'
expected='6107dc417de87bf974e5b225a2632e2c78f2849265dc897981f482e922050ec9'
r=requests.get(f'https://huggingface.co/{repo}/resolve/{sha}/{name}',timeout=300);r.raise_for_status()
assert hashlib.sha256(r.content).hexdigest()==expected,'Model checksum mismatch'
p=pathlib.Path('PhotoApp/RealESRGAN.mlmodel');p.write_bytes(r.content)
spec=ct.utils.load_spec(str(p))
network_before=spec.neuralNetwork.SerializeToString()
for feature in spec.description.input:
 if feature.type.HasField('imageType'):
  feature.type.imageType.width=128;feature.type.imageType.height=128
for feature in spec.description.output:
 if feature.type.HasField('imageType'):
  feature.type.imageType.width=512;feature.type.imageType.height=512
assert network_before==spec.neuralNetwork.SerializeToString(), 'Network weights must remain unchanged'
ct.utils.save_spec(spec,str(p))
report={'mobile_tile':128,'weights_unchanged':True,'repo':repo,'revision':sha,'sha256':expected,'bytes':len(r.content),'input':str(spec.description.input),'output':str(spec.description.output)}
pathlib.Path('model-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
assert any(x.type.HasField('imageType') for x in spec.description.input),'Model must accept image input'
# Include the upstream BSD license alongside the packaged model.
u='https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE'
license=requests.get(u,timeout=60);license.raise_for_status();pathlib.Path('PhotoApp/RealESRGAN-LICENSE.txt').write_text(license.text)
