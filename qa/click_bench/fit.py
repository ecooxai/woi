import json,sys,numpy as np
rows=json.load(open(sys.argv[1])); scale=float(sys.argv[2]) if len(sys.argv)>2 else 1.25
L={i:{t['id']:t for t in json.load(open(f'layout{i}.json'))['targets']} for i in range(4)}
ex,ey,ax,ay=[],[],[],[]
for r in rows:
    if not r['args'] or 'x' not in r['args']: continue
    t=L[r['layout']][r['id']]
    ex.append((t['x']+t['w']/2)/scale); ey.append((t['y']+t['h']/2)/scale); ax.append(r['args']['x']); ay.append(r['args']['y'])
ex,ey,ax,ay=map(np.array,(ex,ey,ax,ay))
for n,e,a_ in (('x',ex,ax),('y',ey,ay)):
    A=np.vstack([e,np.ones_like(e)]).T; (k,b),res,_,_=np.linalg.lstsq(A,a_,rcond=None)
    resid=a_-(k*e+b)
    print(f"{n}: model = {k:.3f}*expected + {b:.1f}; resid median abs {np.median(abs(resid)):.1f}; raw median abs err {np.median(abs(a_-e)):.1f}; mean signed {np.mean(a_-e):.1f}")
