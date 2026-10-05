#!/usr/bin/env python3
"""Offline renderer; Python standard library and FFmpeg 6 with libx264."""
import subprocess as sp
from pathlib import Path
import math

OUT=Path('artifacts'); WORK=Path('test/scratch/launch'); PL=Path('marketing/kit/plates')
OUT.mkdir(exist_ok=True); WORK.mkdir(parents=True,exist_ok=True)
def ff(args):
    sp.run(['ffmpeg','-y','-v','error','-threads','2','-filter_complex_threads','1',*map(str,args)],check=True)
def render(aspect):
    wide=aspect=='16x9'
    W,H=(1920,1080) if wide else (1080,1080)
    CW,CH=(8320,4680) if wide else (8028,8028)
    PX,PY,OW,OH=(3339,1478,1642,2002) if wide else (3194,3153,1640,2000)
    scale=CW*(.85 if wide else .88)/3264
    NW,NH=round(3264*scale),round(1400*scale)
    comp=WORK/f'composite-{aspect}.png'
    ff(['-i',PL/'note-master.png','-i',PL/'portrait-detail.png','-filter_complex',
        f'[0:v]scale={NW}:{NH}:flags=lanczos,format=rgb24,pad={CW}:{CH}:(ow-iw)/2:(oh-ih)/2:color=0x16202E[bg];'
        f'[1:v]crop=1640:2000:204:24,scale={OW}:{OH}:flags=lanczos,format=rgba,'
        f"geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*clip((1-hypot((X-{OW/2})/{OW/2+18},(Y-{OH/2})/{OH/2-8}))/0.012,0,1)'[ov];"
        f'[bg][ov]overlay={PX}:{PY},format=rgb24[out]', '-map','[out]','-frames:v','1','-update','1',comp])
    # All changed eye pixels lie in this band; all plates share exact surrounding art.
    BX,BY,BW,BH=292,708,1180,287
    bw,bh=round(BW*OW/1640),round(BH*OH/2000)
    band=[]
    # 0-4: looking away, open -> closed. 5-8: looking AT you, open -> quarter open (closed is shared, 4).
    for name in ['portrait-detail','blink-075','blink-050','blink-025','blink-000',
                 'portrait-look','blink-look-075','blink-look-050','blink-look-025']:
        band.append(sp.check_output(['ffmpeg','-v','error','-threads','2','-i',str(PL/f'{name}.png'),'-vf',f'crop={BW}:{BH}:{204+BX}:{24+BY},scale={bw}:{bh}:flags=lanczos','-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','pipe:1']))
    blink=WORK/f'blink-{aspect}.mkv'
    p=sp.Popen(['ffmpeg','-y','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{bw}x{bh}','-r','30','-i','pipe:0','-c:v','ffv1','-threads','2',str(blink)],stdin=sp.PIPE)
    # The blink, moved earlier so the stare holds ~0.7 s before the hit: lids close looking away
    # (TB to TB+0.12), hold, and reopen looking straight at the viewer (TB+0.16 to TB+0.32).
    TB=5.45
    away=[0,1,2,3,4]; at=[5,6,7,8,4]
    def mix(seq,v):
        lo=min(4,int(v)); hi=min(4,lo+1); a=v-lo
        A,B=band[seq[lo]],band[seq[hi]]
        return A if a<1e-8 else bytes(round(x*(1-a)+y*a) for x,y in zip(A,B))
    for n in range(195):
        t=n/30-TB
        if t<0: data=band[0]
        elif t<0.16: data=mix(away,min(t/.12,1)*4)
        elif t<0.32: data=mix(at,(1-(t-.16)/.16)*4)
        else: data=band[5]
        p.stdin.write(data)
    p.stdin.close(); assert p.wait()==0
    s='(0.5*(on/194)+0.5*(on/194)*(on/194)*(3-2*(on/194)))'
    z=(CW/1480) if wide else (CW/1250)
    cy1=2478.67 if wide else 4152.52
    push=WORK/f'push-{aspect}.mkv'
    filt=(f'[0:v][1:v]overlay={PX+round(BX*OW/1640)}:{PY+round(BY*OH/2000)}[b];'
          f"[b]zoompan=z='pow({z},{s})':x='{CW/2}-iw/zoom/2':y='{CH/2}+({cy1}-{CH/2})*{s}-ih/zoom/2':d=1:s={W*2}x{H*2}:fps=30,scale={W}:{H}:flags=lanczos,format=rgb24,split[p][e];"
          '[e]format=gray,sobel,gblur=sigma=2,format=gray[edges];'
          f"color=black:s={W}x{H}:r=30,format=gray,geq=lum='255*exp(-pow(((X*0.5+Y*0.866)/{W}-(-0.45+2*T/6.5))/0.13,2))'[band];"
          '[edges][band]blend=all_mode=multiply,format=gbrp[shim];[p]format=gbrp[pc];'
          '[pc][shim]blend=all_mode=screen:all_opacity=0.40,format=gbrp[v]')
    print(f'Rendering push {aspect}; master scale {scale:.9f}; oval scale {OW/757.68:.9f}',flush=True)
    ff(['-loop','1','-framerate','30','-i',comp,'-i',blink,'-filter_complex',filt,'-map','[v]','-frames:v','195','-c:v','ffv1','-threads','2',push])
    flash=WORK/f'flash-{aspect}.mkv'; card=WORK/f'card-{aspect}.mkv'
    ff(['-f','lavfi','-i',f'color=0xF7F5EF:s={W}x{H}:r=30','-vf','format=gbrp','-frames:v','2','-c:v','ffv1',flash])
    ff(['-loop','1','-framerate','30','-i',f'marketing/kit/endcard/endcard-{W}x{H}.png','-vf','format=gbrp','-frames:v','103','-c:v','ffv1',card])
    listing=WORK/f'list-{aspect}.txt'; listing.write_text(''.join(f"file '{x.name}'\n" for x in [push,flash,card]))
    ff(['-f','concat','-safe','0','-i',listing,'-i','marketing/music/imdusd-anthem.wav','-map','0:v','-map','1:a','-vf','fps=30,format=yuv420p','-c:v','libx264','-threads','2','-preset','slow','-crf','17','-profile:v','high','-level','4.0','-x264-params','keyint=30:min-keyint=1:scenecut=0','-c:a','aac','-b:a','256k','-ar','48000','-ac','2','-t','10','-movflags','+faststart',OUT/f'launch-{aspect}.mp4'])
    ff(['-i',OUT/f'launch-{aspect}.mp4','-vf','select=eq(n\\,90)','-frames:v','1','-update','1',OUT/f'poster-{aspect}.png'])
    print(f'Finished {aspect}',flush=True)
if __name__=='__main__':
    for aspect in ['16x9','1x1']: render(aspect)
