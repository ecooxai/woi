#!/usr/bin/env python3
"""Controlled local Brave page for the external_input Android test group.
Run from any directory; expose port 8765 with adb reverse tcp:8765 tcp:8765.
Only synthetic markers and a scroll offset are served. No external resources.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
PAGE = '<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Woi input acceptance</title><style>body{margin:0;font:22px sans-serif;color:#18202a;background:#fff}header{position:sticky;top:0;padding:16px;background:#edf4ff;border-bottom:2px solid #315c8a;z-index:1}h1{font-size:24px;margin:8px}p{min-height:100px;padding:18px;margin:0;border-bottom:1px solid #ccc}#position{font-weight:bold}</style></head><body><header><h1>Woi input acceptance</h1><div id="position" role="status" aria-live="polite">Woi scroll position: 0</div></header><p>Woi marker 01</p><p>Woi marker 02</p><p>Woi marker 03</p><p>Woi marker 04</p><p>Woi marker 05</p><p>Woi marker 06</p><p>Woi marker 07</p><p>Woi marker 08</p><p>Woi marker 09</p><p>Woi marker 10</p><p>Woi marker 11</p><p>Woi marker 12</p><p>Woi marker 13</p><p>Woi marker 14</p><p>Woi marker 15</p><p>Woi marker 16</p><p>Woi marker 17</p><p>Woi marker 18</p><p>Woi marker 19</p><p>Woi marker 20</p><p>Woi marker 21</p><p>Woi marker 22</p><p>Woi marker 23</p><p>Woi marker 24</p><p>Woi marker 25</p><p>Woi marker 26</p><p>Woi marker 27</p><p>Woi marker 28</p><p>Woi marker 29</p><p>Woi marker 30</p><p>Woi marker 31</p><p>Woi marker 32</p><p>Woi marker 33</p><p>Woi marker 34</p><p>Woi marker 35</p><p>Woi marker 36</p><p>Woi marker 37</p><p>Woi marker 38</p><p>Woi marker 39</p><p>Woi marker 40</p><p>Woi marker 41</p><p>Woi marker 42</p><p>Woi marker 43</p><p>Woi marker 44</p><p>Woi marker 45</p><p>Woi marker 46</p><p>Woi marker 47</p><p>Woi marker 48</p><p>Woi marker 49</p><p>Woi marker 50</p><p>Woi marker 51</p><p>Woi marker 52</p><p>Woi marker 53</p><p>Woi marker 54</p><p>Woi marker 55</p><p>Woi marker 56</p><p>Woi marker 57</p><p>Woi marker 58</p><p>Woi marker 59</p><p>Woi marker 60</p><p>Woi marker 61</p><p>Woi marker 62</p><p>Woi marker 63</p><p>Woi marker 64</p><p>Woi marker 65</p><p>Woi marker 66</p><p>Woi marker 67</p><p>Woi marker 68</p><p>Woi marker 69</p><p>Woi marker 70</p><p>Woi marker 71</p><p>Woi marker 72</p><p>Woi marker 73</p><p>Woi marker 74</p><p>Woi marker 75</p><p>Woi marker 76</p><p>Woi marker 77</p><p>Woi marker 78</p><p>Woi marker 79</p><p>Woi marker 80</p><script>let pending=false;function update(){document.getElementById(\'position\').textContent=\'Woi scroll position: \'+Math.round(scrollY);pending=false}addEventListener(\'scroll\',()=>{if(!pending){pending=true;requestAnimationFrame(update)}});update();</script></body></html>'.encode("utf-8")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/woi-input":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_args):
        pass

if __name__ == "__main__":
    print("Woi controlled fixture: http://127.0.0.1:8765/woi-input", flush=True)
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
