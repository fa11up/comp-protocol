#!/usr/bin/env python3
"""Verify encoded bytes, frame timing, flash, static card, posters and MP4 box order."""
import json, subprocess as sp, struct, array, math
from pathlib import Path

def probe(path, extra):
    return json.loads(sp.check_output(['ffprobe','-v','error',*extra,'-of','json',str(path)]))
def boxes(path):
    result=[]
    with path.open('rb') as f:
        while h:=f.read(8):
            size,kind=struct.unpack('>I4s',h); header=8
            if size==1: size=struct.unpack('>Q',f.read(8))[0]; header=16
            result.append(kind.decode());
            if size==0: break
            f.seek(size-header,1)
    return result
reports={}
for aspect,w in [('16x9',1920),('1x1',1080)]:
    path=Path(f'artifacts/launch-{aspect}.mp4')
    data=probe(path,['-count_frames','-show_streams','-show_format'])
    v=next(s for s in data['streams'] if s['codec_type']=='video')
    a=next(s for s in data['streams'] if s['codec_type']=='audio')
    assert (v['codec_name'],v['pix_fmt'],v['width'],v['height'],v['r_frame_rate'],v['nb_read_frames'])==('h264','yuv420p',w,1080,'30/1','300')
    assert a['codec_name']=='aac' and a['sample_rate']=='48000' and a['channels']==2
    assert float(data['format']['duration'])==10 and float(v['duration'])==10 and float(a['duration'])==10
    frames=probe(path,['-select_streams','v:0','-show_frames','-show_entries','frame=pts_time'])['frames']
    assert float(frames[195]['pts_time'])==6.5
    assert abs(float(frames[197]['pts_time'])-197/30)<1e-6
    raw=sp.check_output(['ffmpeg','-v','error','-i',str(path),'-vf','scale=1:1','-pix_fmt','rgb24','-f','rawvideo','pipe:1'])
    means=[list(raw[i:i+3]) for i in range(0,len(raw),3)]
    assert all(min(means[n])>230 for n in [195,196])
    assert sum(means[194])<sum(means[195])-60 and sum(means[197])<sum(means[196])-3
    assert max(abs(means[n][c]-means[197][c]) for n in range(197,300) for c in range(3))<=1
    def pcm(source):
        return array.array('h',sp.check_output(['ffmpeg','-v','error','-ss','6.25','-i',str(source),'-t','0.5','-ac','1','-ar','48000','-f','s16le','pipe:1']))
    reference=pcm('marketing/music/imdusd-anthem.wav'); encoded=pcm(path)
    indices=range(100, min(len(reference),len(encoded))-100, 10)
    correlations={}
    for lag in range(-48,49):
        xy=sum(reference[i]*encoded[i+lag] for i in indices)
        xx=sum(reference[i]**2 for i in indices)
        yy=sum(encoded[i+lag]**2 for i in indices)
        correlations[lag]=xy/math.sqrt(xx*yy)
    lag=max(correlations,key=correlations.get)
    assert abs(lag)<=1 and correlations[lag]>.98
    order=boxes(path); assert order.index('moov')<order.index('mdat')
    assert path.stat().st_size<64*1024**2
    # Exact RGB match between decoded frame 90 and the delivered PNG.
    frame=sp.check_output(['ffmpeg','-v','error','-i',str(path),'-vf','select=eq(n\\,90)','-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','pipe:1'])
    poster=sp.check_output(['ffmpeg','-v','error','-i',f'artifacts/poster-{aspect}.png','-pix_fmt','rgb24','-f','rawvideo','pipe:1'])
    assert frame==poster
    reports[aspect]={'video':{k:v[k] for k in ['codec_name','pix_fmt','width','height','r_frame_rate','nb_read_frames','duration']},'audio':{k:a[k] for k in ['codec_name','sample_rate','channels','duration']},'cut_pts_seconds':frames[195]['pts_time'],'endcard_pts_seconds':frames[197]['pts_time'],'cut_frame_means_rgb':{str(n):means[n] for n in [194,195,196,197]},'mp4_box_order':order,'bytes':path.stat().st_size,'poster_exact_frame_90':True,'audio_alignment_near_hit':{'lag_samples':lag,'correlation':correlations[lag]}}
assert sum(p.stat().st_size for p in Path('artifacts').glob('*') if p.is_file())<128*1024**2
Path('marketing/launch/verification.json').write_text(json.dumps(reports,indent=2)+'\n')
print(json.dumps(reports,indent=2))
