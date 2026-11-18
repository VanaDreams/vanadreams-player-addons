"""Isolated LuaJIT tests: real addon/parser/tracker with mocked Ashita/ImGui.
Does not load into FFXI, inject packets, or install anything.
"""
from pathlib import Path
import struct
import random
import pytest
from lupa.luajit21 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]


def packet(actor=100, targets=None, category=1):
    targets=targets if targets is not None else [(1000,None)]
    bits=[0]*40
    def put(n,w): bits.extend((n>>i)&1 for i in range(w))
    put(actor,32);put(len(targets),6);put(0,4);put(category,4);put(0,32);put(0,32)
    for target,level in targets:
        put(target,32);put(1,4)
        for n,w in [(0,3),(0,2),(0,12),(0,5),(0,5),(50,17),(1,10),(0,31)]:put(n,w)
        put(level is not None,1)
        if level is not None:
            for n,w in [(7,6),(0,4),(level,17),(603,10)]:put(n,w)
        put(0,1)
    out=bytearray((len(bits)+7)//8)
    for i,b in enumerate(bits):out[i//8]|=b<<(i%8)
    out[4]=len(out)
    return bytes(out)


@pytest.fixture
def rt():
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().addon_path=ROOT.as_posix()
    lua.execute(r"""
package.path=addon_path..'/?.lua;'..package.path
package.preload.common=function()
 T=function(t)return t end
 bit=require('bit')
 switch=setmetatable({default={}}, {__call=function(s,k,t)return (t[k] or t[s.default])()end})
 string.tohex=function(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
 string.replace=function(s,a,b)return (s:gsub(a,b))end
 string.args=function(s)local t={};for word in s:gmatch('%S+')do t[#t+1]=word end;return t end
end
struct={unpack=function(fmt,s,pos)
 local size=fmt=='I' and 4 or 2;local n=0
 assert(#s>=pos+size-1)
 for i=0,size-1 do n=n+s:byte(pos+i)*2^(8*i) end
 return n,pos+size
end}
addon={};callbacks={};printed={};texts={};begins=0;ends=0;visible=true
print=function(s)printed[#printed+1]=s end
ashita={events={register=function(event,name,fn)callbacks[event]=fn end}}
ImGuiCond_FirstUseEver=1;ImGuiWindowFlags_NoDecoration=1;ImGuiWindowFlags_AlwaysAutoResize=2
ImGuiWindowFlags_NoFocusOnAppearing=4;ImGuiWindowFlags_NoNav=8;ImGuiWindowFlags_NoBringToFrontOnFocus=16
package.preload.imgui=function()return {
 SetNextWindowPos=function()end,Begin=function()begins=begins+1;return visible end,
 End=function()ends=ends+1 end,Text=function(s)texts[#texts+1]=s end,Separator=function()end}end
job=6;login=2;members={[0]=100,[1]=101};slotsRead={}
local player={GetLoginStatus=function()return login end,GetMainJob=function()return job end}
local party={GetMemberServerId=function(_,slot)slotsRead[slot]=true;return members[slot] or 0 end}
local memory={GetPlayer=function()return player end,GetParty=function()return party end}
AshitaCore={GetMemoryManager=function()return memory end}
GetEntity=function(index)
 if index==0 then return {ServerId=100,Name='Player'} end
 if index==1 then return {ServerId=101,Name='Ally'} end
 if index>=2 and index<=20 then return {ServerId=998+index,Name='Mob'..(998+index)} end
end
function receive(id,data,injected)callbacks.packet_in({id=id,data=data,injected=injected})end
function render()texts={};callbacks.d3d_present();return table.concat(texts,'|')end
function command(s)local e={command=s};callbacks.command(e);return e.blocked end
""")
    lua.execute((ROOT/'easyTH.lua').read_text(encoding='utf-8'))
    return lua


def recv(rt,actor=100,targets=None,category=1):
    rt.globals().receive(0x28,packet(actor,targets,category),False)


def test_real_parser_reads_server_th_fields(rt):
    rt.globals().data=packet(targets=[(1000,9)])
    rt.execute("p=require('parser').parse(data);assert(p.m_uID==100 and p.cmd_no==1);r=p.target[1].result[1];assert(r.proc_kind==7 and r.proc_message==603 and r.proc_value==9)")


def test_new_party_target_does_not_inherit_current_mob_level(rt):
    recv(rt,targets=[(1000,8)])
    assert 'TH Lvl: 8' in rt.globals().render()
    recv(rt,actor=101,targets=[(1001,None)])
    assert 'Mob1000' in rt.globals().render()
    recv(rt,targets=[(1001,None)])
    assert 'Unknown (no proc observed)' in rt.globals().render()
    recv(rt,targets=[(1000,None)])
    assert 'TH Lvl: 8' in rt.globals().render()


def test_no_inferred_base_or_zero_from_first_thf_action(rt):
    recv(rt)
    display=rt.globals().render()
    assert 'Unknown (no proc observed)' in display and 'Base' not in display


@pytest.mark.parametrize('slot',range(18))
def test_all_alliance_slots_observed_regardless_of_job(rt,slot):
    rt.globals().members[slot]=200+slot
    recv(rt,actor=200+slot,targets=[(1000,11)])
    assert 'TH Lvl: 11' in rt.globals().render()
    assert all(rt.globals().slotsRead[i] for i in range(18))


def test_anyjob_without_thf_party_observes_but_does_not_guess_gear_th(rt):
    rt.execute('job=1;members={[0]=100}')
    recv(rt,targets=[(1000,8)])
    assert rt.globals().render()==''
    rt.globals().command('/easyth anyjob')
    recv(rt)
    assert 'Unknown' in rt.globals().render()
    recv(rt,targets=[(1000,5)])
    assert 'TH Lvl: 5' in rt.globals().render()


def test_all_targets_independent_and_latest_server_level_authoritative(rt):
    recv(rt,targets=[(1000,7),(1001,10)])
    recv(rt,targets=[(1001,None)])
    assert 'TH Lvl: 10' in rt.globals().render()
    recv(rt,targets=[(1001,8)])
    assert 'TH Lvl: 8' in rt.globals().render()


@pytest.mark.parametrize('message',[6,20])
def test_death_forgets_level(rt,message):
    recv(rt,targets=[(1000,12)])
    data=bytearray(28);struct.pack_into('<I',data,8,1000);struct.pack_into('<H',data,24,message)
    rt.globals().receive(0x29,bytes(data),False)
    assert rt.globals().render()==''
    recv(rt)
    assert 'Unknown' in rt.globals().render()


@pytest.mark.parametrize('event',[0xA,0xB])
def test_zone_reset(rt,event):
    recv(rt,targets=[(1000,8)])
    rt.globals().receive(event,b'',False)
    assert rt.globals().render()==''


def test_logout_reset_and_command_reset(rt):
    recv(rt,targets=[(1000,8)])
    rt.execute('login=0');assert rt.globals().render()==''
    rt.execute('login=2');recv(rt);assert 'Unknown' in rt.globals().render()
    assert rt.globals().command('/easyth reset')
    assert rt.globals().render()==''
    assert not rt.globals().command('/other reset')


def test_imgui_end_balanced_when_begin_false(rt):
    recv(rt);rt.execute('visible=false');rt.globals().render()
    assert rt.globals().begins==rt.globals().ends==1


@pytest.mark.parametrize('category',[0,2,4,5,6,7,8,9,10,11,12,14,15])
def test_other_action_categories_ignored(rt,category):
    recv(rt,targets=[(1000,8)],category=category)
    assert rt.globals().render()==''


def test_ws_category_supported(rt):
    recv(rt,targets=[(1000,8)],category=3)
    assert 'TH Lvl: 8' in rt.globals().render()


def test_nonparty_and_injected_packets_ignored(rt):
    recv(rt,actor=999,targets=[(1000,8)])
    rt.globals().receive(0x28,packet(targets=[(1000,8)]),True)
    assert rt.globals().render()==''


def test_every_truncated_prefix_safely_ignored(rt):
    data=packet(targets=[(1000,8)])
    for end in range(len(data)-1):
        rt.globals().receive(0x28,data[:end],False)
        assert rt.globals().render()==''
    for end in range(26):rt.globals().receive(0x29,bytes(end),False)


def test_malformed_fuzz_does_not_escape_callback(rt):
    rng=random.Random(183)
    for i in range(1000):
        data=bytearray(rng.randbytes(rng.randrange(19,120)))
        struct.pack_into('<I',data,5,100);data[10]=(data[10]&0xC3)|4
        rt.globals().receive(0x28,bytes(data),False)
        rt.globals().command('/easyth reset')
    assert rt.globals().render()==''


def test_invalid_field_counts_and_oversized_data_rejected(rt):
    data=bytearray(packet(targets=[(1000,8)]));data[9]=63
    rt.globals().receive(0x28,bytes(data),False)
    rt.globals().receive(0x28,packet()+bytes(4097),False)
    assert rt.globals().render()==''
