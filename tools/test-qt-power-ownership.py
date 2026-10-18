from pathlib import Path
s=Path('src/systembackend.cpp').read_text(encoding='utf-8-sig')
def body(name):
 a=s.index(name);a=s.index('{',a);depth=1;b=a+1
 while depth:
  depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
assert 'scaling_min_freq' not in s, 'Qt must not manipulate CPU minimum'
for name in ['SystemBackend::activateInteractiveCpuBoost(', 'SystemBackend::releaseInteractiveCpuBoost(', 'SystemBackend::setScreenSleeping(']:
 assert 'scaling_' not in body(name), 'Qt policy write remains: '+name
assert 'cpufreq-sleep.state' not in s and 'cpufreq-boost.state' not in s
assert 'screen-sleeping' in s and 'QSaveFile marker' in s
assert 'SystemBackend::~SystemBackend' in s
print('Qt CPU policy ownership source checks passed')
