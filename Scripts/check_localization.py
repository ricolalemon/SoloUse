# UI localization coverage; presentation only. Does not modify files.
from pathlib import Path
import re,json
def string_end(s,i):
 j=i+1
 while j<len(s):
  if s[j]=='"':return j+1
  if s[j]=='\\':
   if s[j+1:j+2]=='(':
    j=expression_end(s,j+2)
   else:j+=2
  else:j+=1
 raise ValueError('Unterminated string')
def expression_end(s,j):
 depth=1
 while j<len(s):
  if s[j]=='"': j=string_end(s,j)
  elif s[j]=='(':depth+=1;j+=1
  elif s[j]==')':
   depth-=1;j+=1
   if depth==0:return j
  else:j+=1
 raise ValueError('Unterminated interpolation')
def literals(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   j=s.find('\n',i);i=len(s) if j<0 else j+1
  elif s.startswith('/*',i):
   j=s.find('*/',i+2);i=len(s) if j<0 else j+2
  elif s.startswith('"""',i):
   j=s.find('"""',i+3);i=len(s) if j<0 else j+3
  elif s[i]=='"':
   j=string_end(s,i);yield i,j,s[i:j];i=j
  else:i+=1
def key(token):
 s=token[1:-1];out='';i=0;count=0
 while i<len(s):
  if s.startswith('\\(',i):
   end=expression_end(s,i+2);out+='{'+str(count)+'}';count+=1;i=end
  else:out+=s[i];i+=1
 return json.loads('"'+out+'"')
if __name__ == '__main__':
 root=Path(__file__).resolve().parents[1]/'App'
 entries=json.loads((root/'Resources/Localizations.json').read_text())
 issues=[]
 for p in list(root.glob('*View.swift'))+[root/'InterfaceComponents.swift',root/'TaskNotifications.swift']:
  s=p.read_text()
  for a,b,t in literals(s):
   if not re.search('[\u3400-\u9fff]',t):continue
   k=key(t)
   if not re.search('[\u3400-\u9fff]',k) or k in ['Language / 语言','简体中文']:continue
   if k not in entries:issues.append((p.name,k))
   if not s[:a].endswith('L10n.text('):issues.append((p.name,'Not localized: '+k))
 s=(root/'PhoneAgentView.swift').read_text()
 assert 'Text(entry.text).textSelection' in s and 'MarkdownMessageView(source: entry.text)' in s
 s=(root/'InterfaceComponents.swift').read_text()
 assert 'Text(question)' in s and 'Text(choice)' in s
 assert not issues,issues
 print('PASS UI literal coverage and unmodified user/assistant/question rendering')
