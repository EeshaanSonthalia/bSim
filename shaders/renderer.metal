#include <metal_stdlib>
using namespace metal;
struct Params {
    float4 camera, composition, disk, material, color, optics, timing;
    uint4 image, work;
};
struct Map { float4 hits[4]; float4 sky, info; };
struct Ray { float4 position, velocity, constants; uint4 status; };
struct State { float4 p; float2 v; };
float horizon(float a) { return 1+sqrt(1-a*a); }
State deriv(State y, float4 k) {
    float u=y.p.x,r=1/u,s=sin(y.p.y),c=cos(y.p.y),s2=max(s*s,1e-14f);
    float a=k.x,e=k.y,l=k.z,d=r*r-2*r+a*a,p=e*(r*r+a*a)-a*l;
    float capK=(l-a*e)*(l-a*e)+k.w;
    return {float4(y.v,l/s2-a*e+a*p/d,a*(l-a*e*s2)+(r*r+a*a)*p/d),float2((a*a*e*e-l*l-k.w)*u+3*capK*u*u-2*a*a*k.w*u*u*u,c*(l*l/(s2*s)-a*a*e*e*s))};
}
State stateAdd(State a,State b,float scale) { return {a.p+scale*b.p,a.v+scale*b.v}; }
bool advance(thread Ray &ray,float tol,thread State &old,thread float &usedH) {
    old={ray.position,ray.velocity.xy};
    float h=min(ray.velocity.z,0.075f*max(old.p.x,0.005f));
    if(old.v.x>0) h=min(h,0.3f*(1/horizon(ray.constants.x)-old.p.x)/max(abs(old.v.x),1.0f));
    for(uint attempt=0;attempt<16;attempt++) {
        if(h<1e-9f || !isfinite(h)) return false;
        State k0=deriv(old,ray.constants);
        State k1=deriv(stateAdd(old,k0,h/4),ray.constants);
        State k2=deriv(stateAdd(stateAdd(old,k0,h*3/32),k1,h*9/32),ray.constants);
        State k3=deriv(stateAdd(stateAdd(stateAdd(old,k0,h*1932/2197),k1,-h*7200/2197),k2,h*7296/2197),ray.constants);
        State k4=deriv(stateAdd(stateAdd(stateAdd(stateAdd(old,k0,h*439/216),k1,-8*h),k2,h*3680/513),k3,-h*845/4104),ray.constants);
        State k5=deriv(stateAdd(stateAdd(stateAdd(stateAdd(stateAdd(old,k0,-h*8/27),k1,2*h),k2,-h*3544/2565),k3,h*1859/4104),k4,-h*11/40),ray.constants);
        State low=stateAdd(stateAdd(stateAdd(stateAdd(old,k0,h*25/216),k2,h*1408/2565),k3,h*2197/4104),k4,-h/5);
        State high=stateAdd(stateAdd(stateAdd(stateAdd(stateAdd(old,k0,h*16/135),k2,h*6656/12825),k3,h*28561/56430),k4,-h*9/50),k5,h*2/55);
        float4 ep=abs(high.p-low.p)/(1+max(abs(old.p),abs(high.p)));
        float2 ev=abs(high.v-low.v)/(1+max(abs(old.v),abs(high.v)));
        float err=max(max(max(ep.x,ep.y),max(ep.z,ep.w)),max(ev.x,ev.y));
        if(!all(isfinite(high.p)) || !all(isfinite(high.v))) return false;
        float factor=clamp(0.9f*pow(tol/max(err,1e-20f),0.2f),0.2f,2.0f);
        if(err<=tol) {
            ray.position=high.p; ray.velocity=float4(high.v,h*factor,max(ray.velocity.w,err));
            usedH=h; ray.status.z++; return true;
        }
        h*=factor;
    }
    return false;
}
float constraint(Ray ray) {
    float4 k=ray.constants,p=ray.position;
    float u=p.x,a=k.x,e=k.y,l=k.z,s=sin(p.y),c=cos(p.y);
    float capK=(l-a*e)*(l-a*e)+k.w;
    float radial=e*e+(a*a*e*e-l*l-k.w)*u*u+2*capK*u*u*u-a*a*k.w*u*u*u*u;
    float polar=k.w-c*c*(l*l/(s*s)-a*a*e*e);
    return max(abs(ray.velocity.x*ray.velocity.x-radial)/(1+e*e),abs(ray.velocity.y*ray.velocity.y-polar)/(1+abs(k.w)+l*l));
}
kernel void rayInit(device Ray *rays [[buffer(0)]],device uint *queue [[buffer(1)]],device Map *maps [[buffer(2)]],constant Params &p [[buffer(3)]],uint id [[thread_position_in_grid]]) {
    if(id>=p.work.y) return;
    uint pixel=p.work.x+id,x=pixel%p.image.x,y=pixel/p.image.x;
    float2 screen=float2((2*(float(x)+0.5f)-float(p.image.x))/float(p.image.y),1-2*(float(y)+0.5f)/float(p.image.y));
    screen+=p.composition.yz;
    screen*=tan(p.camera.w*0.5f);
    float cr=cos(p.composition.x),sr=sin(p.composition.x);
    float3 n=normalize(float3(-1,-(screen.y*cr+screen.x*sr),screen.x*cr-screen.y*sr));
    float r=p.camera.x,theta=p.camera.y,a=p.disk.x,s=sin(theta),c=cos(theta);
    float sigma=r*r+a*a*c*c,delta=r*r-2*r+a*a,bigA=(r*r+a*a)*(r*r+a*a)-a*a*delta*s*s;
    float gamma=rsqrt(1-p.composition.w*p.composition.w),pt=gamma*(-1+p.composition.w*n.z),np=gamma*(n.z-p.composition.w);
    float l=sqrt(bigA/sigma)*s*np,e=sqrt(sigma*delta/bigA)*pt+2*a*r/bigA*l,vt=sqrt(sigma)*n.y;
    rays[id]={float4(1/r,theta,p.camera.z,0),float4(-sqrt(sigma*delta)*n.x/(r*r),vt,0.04f/r,0),float4(a,e,l,vt*vt+c*c*(l*l/(s*s)-a*a*e*e)),uint4(0,0,0,0)};
    maps[id]={}; queue[id]=id;
}
kernel void rayStep(device Ray *rays [[buffer(0)]],device uint *input [[buffer(1)]],device uint *output [[buffer(2)]],device atomic_uint *count [[buffer(3)]],device Map *maps [[buffer(4)]],constant Params &p [[buffer(5)]],constant uint &active [[buffer(6)]],uint id [[thread_position_in_grid]]) {
    if(id>=active) return;
    uint index=input[id]; Ray ray=rays[index]; Map map=maps[index];
    for(uint step=0;step<32;step++) {
        if(ray.position.x>=1/(horizon(ray.constants.x)+0.001f) && ray.velocity.x>0) {ray.status.x=2;break;}
        if(ray.position.x<=0.005f && ray.velocity.x<0) {ray.status.x=1;break;}
        if(ray.status.z>=p.image.z) {ray.status.x=3;break;}
        State old;float h;
        if(!advance(ray,p.optics.w,old,h)) {ray.status.x=3;break;}
        float drift=constraint(ray); map.info.w=max(map.info.w,drift);
        if(cos(old.p.y)*cos(ray.position.y)<0 && ray.status.y<4) {
            State end={ray.position,ray.velocity.xy},d0=deriv(old,ray.constants),d1=deriv(end,ray.constants);
            float lo=0,hi=1;float4 hit=end.p;
            for(uint i=0;i<16;i++) {
                float t=(lo+hi)*0.5f;
                hit=(2*t*t*t-3*t*t+1)*old.p+(t*t*t-2*t*t+t)*h*d0.p+(-2*t*t*t+3*t*t)*end.p+(t*t*t-t*t)*h*d1.p;
                if(cos(old.p.y)*cos(hit.y)>0) lo=t; else hi=t;
            }
            float hitRadius=1/hit.x;
            if(hitRadius>=p.disk.y && hitRadius<=p.disk.z) {
                float vt=mix(old.v.y,end.v.y,(lo+hi)*0.5f);
                map.hits[ray.status.y++]=float4(hitRadius,hit.z,hit.w,min(1.0f,abs(vt)/hitRadius));
            }
        }
    }
    map.sky=float4(ray.position.yz,ray.velocity.w,float(ray.status.y));
    map.info.xyz=float3(float(ray.status.x),float(ray.status.z),ray.position.w);
    maps[index]=map; rays[index]=ray;
    if(ray.status.x==0) output[atomic_fetch_add_explicit(count,1,memory_order_relaxed)]=index;
}
float3 emission(constant Params &p,float r,float phi,float time,float footprint) {
    float phase=phi-time*p.material.z/(pow(r,1.5f)+p.disk.x),seed=float(p.image.w%1024)*0.013f;
    float filaments=0,norm=0;
    for(uint i=0;i<6;i++) {
        float f=float(i),freq=7*pow(1.9f,f),weight=pow(0.58f,f);
        filaments+=weight*exp(-0.5f*freq*freq*footprint*footprint)*sin(r*freq+2*sin(phase*(3+f)+r*0.4f+seed)+phase*(2+f));
        norm+=weight;
    }
    float edge=smoothstep(p.disk.y,p.disk.y+0.6f,r)*(1-smoothstep(p.disk.z-3,p.disk.z,r));
    float brightness=p.material.w*edge*pow(p.disk.y/max(r,p.disk.y),1.2f)*(0.65f+0.55f*filaments/norm);
    return brightness*p.color.rgb;
}
kernel void shadeMap(device const Map *maps [[buffer(0)]],device float4 *colors [[buffer(1)]],constant Params &p [[buffer(2)]],uint id [[thread_position_in_grid]]) {
    if(id>=p.work.y) return;
    Map m=maps[id]; float3 color=0;float transmission=1;
    uint count=uint(m.sky.w);
    for(uint i=0;i<count;i++) {
        float4 hit=m.hits[i];
        float footprint=0.5f*hit.x*tan(p.camera.w*0.5f)/float(p.image.y);
        if(id>0 && id+1<p.work.y && uint(maps[id-1].sky.w)>i && uint(maps[id+1].sky.w)>i) {
            float delta=abs(maps[id+1].hits[i].x-maps[id-1].hits[i].x)*0.25f;
            footprint=max(footprint,min(delta,0.5f));
        }
        float opacity=1-exp(-p.material.x*p.disk.w*2.506628f/max(hit.w,0.03f));
        color+=transmission*opacity*emission(p,hit.x,hit.y+p.timing.y,p.timing.x+hit.z,footprint);
        transmission*=1-opacity;
    }
    colors[id]=float4(color,1);
}
