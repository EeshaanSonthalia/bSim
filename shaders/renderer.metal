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
uint hash32(uint value) {
    uint mixed=value;
    mixed^=mixed>>16; mixed*=0x7feb352du;
    mixed^=mixed>>15; mixed*=0x846ca68bu;
    mixed^=mixed>>16;
    return mixed;
}
float unit(uint salt,uint key) { return float(hash32(salt^key))*(1.0f/4294967296.0f); }
float noise(uint salt,float x) {
    float cell=floor(x),t=x-cell;
    t=t*t*(3-2*t);
    int index=(int)cell;
    float low=unit(salt,as_type<uint>(index)),high=unit(salt,as_type<uint>(index+1));
    return low+(high-low)*t;
}
float band(uint salt,float x) {
    float value=0,weight=0.5f,scale=1,total=0;
    for(uint octave=0;octave<3;octave++) {
        value+=weight*noise(salt^(octave*0x9e3779b9u),x*scale);
        total+=weight; weight*=0.55f; scale*=2.13f;
    }
    return value/total;
}
float3 emission(constant Params &p,float r,float phi,float time,float footprint) {
    float phase=phi-time*p.material.z/(pow(r,1.5f)+p.disk.x);
    uint salt=p.image.w;
    float undulate=sin(phase),envelope=band(salt,r*0.55f+0.3f*undulate),wobbleAt=r*0.45f+0.35f*undulate;
    float filaments=0,norm=0;
    for(uint i=0;i<6;i++) {
        uint key=i*0x85ebca6bu;
        float f=float(i),freq=7*pow(1.9f,f);
        float strength=pow(0.58f,f)*(0.45f+1.1f*unit(salt,key+1u));
        float attenuation=exp(-0.5f*freq*freq*footprint*footprint);
        float order=float(1u+hash32(salt^(key+2u))%7u),swirlOrder=float(2u+hash32(salt^(key+3u))%6u);
        float swirlPhase=unit(salt,key+4u)*(2*M_PI_F),drift=(unit(salt,key+5u)-0.5f)*(2*M_PI_F);
        float swirl=1.2f+1.6f*unit(salt,key+7u);
        float wobble=(noise(salt^(key+6u),wobbleAt)-0.5f)*M_PI_F;
        filaments+=strength*attenuation*sin(r*freq+wobble+order*phase+swirl*sin(swirlOrder*phase+r*0.4f+swirlPhase)+drift);
        norm+=strength;
    }
    float edge=smoothstep(p.disk.y,p.disk.y+0.6f,r)*(1-smoothstep(p.disk.z-3,p.disk.z,r));
    float brightness=p.material.w*edge*pow(p.disk.y/max(r,p.disk.y),1.2f)*(0.65f+0.55f*envelope*filaments/norm);
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

struct Path { Ray ray; float4 radiance, weight; uint4 info; float4 padding; };
float randomFloat(thread uint &state) {
    state=state*747796405u+2891336453u;
    uint word=((state>>((state>>28u)+4u))^state)*277803737u;
    return clamp((float((word>>22u)^word)+0.5f)*(1.0f/4294967296.0f),1e-7f,1-1e-7f);
}
Ray localRay(float4 position,float a,float3 direction,float velocity) {
    float r=1/position.x,s=sin(position.y),c=cos(position.y);
    float sigma=r*r+a*a*c*c,delta=r*r-2*r+a*a,bigA=(r*r+a*a)*(r*r+a*a)-a*a*delta*s*s;
    float gamma=rsqrt(1-velocity*velocity),pt=gamma*(-1+velocity*direction.z),pp=gamma*(direction.z-velocity);
    float l=sqrt(bigA/sigma)*s*pp,e=sqrt(sigma*delta/bigA)*pt+2*a*r/bigA*l,vt=sqrt(sigma)*direction.y;
    return {position,float4(-sqrt(sigma*delta)*direction.x/(r*r),vt,0.04f/r,0),float4(a,e,l,vt*vt+c*c*(l*l/(s*s)-a*a*e*e)),uint4(0)};
}
struct Frame { float velocity,energy,sigma;float3 direction; };
Frame materialFrame(Ray ray) {
    float4 y=ray.position,k=ray.constants;
    float r=1/y.x,a=k.x,s=sin(y.y),c=cos(y.y),sigma=r*r+a*a*c*c,delta=r*r-2*r+a*a;
    float bigA=(r*r+a*a)*(r*r+a*a)-a*a*delta*s*s,alpha=sqrt(sigma*delta/bigA),omega=2*a*r/bigA,varpi=sqrt(bigA/sigma)*s;
    float velocity=clamp((1/(pow(r,1.5f)+a)-omega)*varpi/alpha,-0.8f,0.8f),gamma=rsqrt(1-velocity*velocity);
    float pt=(k.y-omega*k.z)/alpha,pp=k.z/varpi;
    float3 direction=normalize(float3(-ray.velocity.x*r*r/sqrt(sigma*delta),ray.velocity.y/sqrt(sigma),gamma*(pp-velocity*pt)));
    return {velocity,-gamma*(pt-velocity*pp),sigma,direction};
}
float phasePdf(float cosine,float g) {
    float d=1+g*g-2*g*cosine;
    return (1-g*g)/(4*M_PI_F*d*sqrt(d));
}
float3 samplePhase(float3 axis,float g,thread uint &seed) {
    float u=randomFloat(seed),ratio=(1-g*g)/(1-g+2*g*u);
    float cosine=abs(g)<0.001f?2*u-1:clamp((1+g*g-ratio*ratio)/(2*g),-1.0f,1.0f);
    float sine=sqrt(max(0.0f,1-cosine*cosine)),phi=2*M_PI_F*randomFloat(seed);
    float3 basis=normalize(cross(axis,abs(axis.z)<0.9f?float3(0,0,1):float3(0,1,0))),other=cross(axis,basis);
    return normalize(axis*cosine+sine*(cos(phi)*basis+sin(phi)*other));
}
uint directionBin(float3 direction) {
    float azimuth=atan2(direction.z,direction.x);if(azimuth<0)azimuth+=2*M_PI_F;
    return min(3u,uint((direction.y+1)*2))*8+min(7u,uint(azimuth*(4/M_PI_F)));
}
float3 guideSample(device const float *guide,uint band,thread uint &seed,thread float &pdf) {
    float sum=0;for(uint i=0;i<32;i++)sum+=guide[band*32+i];
    float target=randomFloat(seed)*sum;uint bin=31;
    for(uint i=0;i<32;i++) {target-=guide[band*32+i];if(target<=0){bin=i;break;}}
    float y=-1+0.5f*(float(bin/8)+randomFloat(seed)),phi=(M_PI_F/4)*(float(bin%8)+randomFloat(seed));
    float radius=sqrt(max(0.0f,1-y*y));pdf=guide[band*32+bin]/sum*(8/M_PI_F);
    return float3(radius*cos(phi),y,radius*sin(phi));
}
float guidePdf(device const float *guide,uint band,float3 direction) {
    float sum=0;for(uint i=0;i<32;i++)sum+=guide[band*32+i];
    return guide[band*32+directionBin(direction)]/sum*(8/M_PI_F);
}
void addReward(device atomic_uint *destination,uint amount) {
    uint old=atomic_load_explicit(destination,memory_order_relaxed);
    while(true) {
        uint updated=old+min(amount,0x7fffffffu-old);
        if(atomic_compare_exchange_weak_explicit(destination,&old,updated,memory_order_relaxed,memory_order_relaxed))return;
    }
}
kernel void pathInit(device Path *paths [[buffer(0)]],device uint *queue [[buffer(1)]],constant Params &p [[buffer(2)]],device const uchar *mask [[buffer(3)]],uint id [[thread_position_in_grid]]) {
    if(id>=p.work.y*2)return;
    uint pixel=p.work.x+id/2,x=pixel%p.image.x,y=pixel/p.image.x;
    uint seed=p.image.w^(pixel*1664525u)^(p.work.z*1013904223u);
    float2 jitter=float2(randomFloat(seed),randomFloat(seed));
    float2 screen=float2((2*(float(x)+jitter.x)-float(p.image.x))/float(p.image.y),1-2*(float(y)+jitter.y)/float(p.image.y));
    screen=(screen+p.composition.yz)*tan(p.camera.w*0.5f);
    float cr=cos(p.composition.x),sr=sin(p.composition.x);
    float3 direction=normalize(float3(-1,-(screen.y*cr+screen.x*sr),screen.x*cr-screen.y*sr));
    Ray ray=localRay(float4(1/p.camera.x,p.camera.y,p.camera.z,0),p.disk.x,direction,p.composition.w);
    if(!mask[id/2] || (id%2==1 && p.material.y==0))ray.status.x=4;
    paths[id]={ray,float4(0),float4(1,0,0,-log(randomFloat(seed))),uint4(id%2,0,seed,0xffffffffu),float4(0)};
    queue[id]=id;
}
kernel void pathStep(device Path *paths [[buffer(0)]],device const uint *input [[buffer(1)]],device uint *output [[buffer(2)]],device atomic_uint *count [[buffer(3)]],constant Params &p [[buffer(4)]],constant uint &active [[buffer(5)]],device const float *guide [[buffer(6)]],device atomic_uint *learning [[buffer(7)]],uint id [[thread_position_in_grid]]) {
    if(id>=active)return;
    uint index=input[id];Path path=paths[index];Ray ray=path.ray;uint seed=path.info.z;
    for(uint iteration=0;iteration<24 && ray.status.x==0;iteration++) {
        float r=1/ray.position.x;
        if((r<=horizon(p.disk.x)+0.001f && ray.velocity.x>0)||(r>=200 && ray.velocity.x<0)){ray.status.x=1;break;}
        if(ray.status.z>=p.image.z*(p.work.w&65535u)){ray.status.x=3;break;}
        float z=r*cos(ray.position.y),dz=-ray.velocity.x*r*r*cos(ray.position.y)-r*sin(ray.position.y)*ray.velocity.y;
        if(r>=p.disk.y-1 && r<=p.disk.z+2) {
            if(abs(z)<6*p.disk.w)ray.velocity.z=min(ray.velocity.z,0.08f*p.disk.w/max(abs(dz),0.01f));
            if(z*dz<0 && abs(z)>=6*p.disk.w)ray.velocity.z=min(ray.velocity.z,max(0.08f*p.disk.w,(abs(z)-4*p.disk.w)*0.5f)/max(abs(dz),0.01f));
        }
        State old;float h;
        if(!advance(ray,p.optics.w,old,h)){ray.status.x=3;break;}
        Ray middle=ray;middle.position=(old.p+ray.position)*0.5f;middle.velocity.xy=(old.v+ray.velocity.xy)*0.5f;
        Frame frame=materialFrame(middle);float radius=1/middle.position.x,height=radius*cos(middle.position.y)/p.disk.w;
        float density=(radius>=p.disk.y && radius<=p.disk.z && abs(height)<8)?p.material.x*exp(-0.5f*height*height):0;
        float tau=density*frame.energy*frame.sigma*h;
        if(tau<=0)continue;
        float3 source=emission(p,radius,middle.position.z,p.timing.x+middle.position.w,0);
        if(path.info.x==0) {
            float opacity=tau<0.01f?tau*(1-0.5f*tau+tau*tau/6):1-exp(-tau);
            path.radiance.rgb+=path.weight.x*opacity*source;path.weight.x*=1-opacity;
            if(path.weight.x<1e-10f){ray.status.x=1;break;}
        } else {
            float travelled=min(tau,path.weight.w);
            if(path.info.y>0)path.radiance.rgb+=path.weight.x*travelled*source;
            if(tau<path.weight.w){path.weight.w-=tau;continue;}
            float fraction=path.weight.w/tau;
            ray.position=mix(old.p,ray.position,fraction);ray.velocity.xy=mix(old.v,ray.velocity.xy,fraction);
            Frame collision=materialFrame(ray);
            uint band=min(3u,uint(clamp((1/ray.position.x-p.disk.y)/(p.disk.z-p.disk.y),0.0f,0.999f)*4));
            float3 direction;float guided=0;bool useGuide=(p.work.w&65536u)!=0;
            if(useGuide && randomFloat(seed)<0.2f)direction=guideSample(guide,band,seed,guided);
            else {direction=samplePhase(collision.direction,p.color.w,seed);if(useGuide)guided=guidePdf(guide,band,direction);}
            float physical=phasePdf(dot(collision.direction,direction),p.color.w);
            float pdf=useGuide?0.8f*physical+0.2f*guided:physical;
            path.weight.x*=p.material.y*physical/pdf;
            if(path.info.y==0)path.info.w=band*32+directionBin(direction);
            uint steps=ray.status.z;
            ray=localRay(ray.position,p.disk.x,direction,collision.velocity);ray.status.z=steps;
            path.info.y++;
            if(path.info.y>=(p.work.w&65535u)){ray.status.x=3;break;}
            if(path.info.y>=3) {
                float survival=clamp(path.weight.x,0.05f,0.95f);
                if(randomFloat(seed)>survival){ray.status.x=1;break;}
                path.weight.x/=survival;
            }
            path.weight.w=-log(randomFloat(seed));
        }
    }
    path.ray=ray;path.info.z=seed;paths[index]=path;
    if(ray.status.x==0)output[atomic_fetch_add_explicit(count,1,memory_order_relaxed)]=index;
    else if(path.info.w<128 && ray.status.x!=3) {
        float reward=dot(path.radiance.rgb,float3(0.2126f,0.7152f,0.0722f));
        addReward(&learning[path.info.w],uint(clamp(reward*4096,0.0f,65535.0f)));
    }
}
kernel void pathResolve(device const Path *paths [[buffer(0)]],device float4 *colors [[buffer(1)]],constant Params &p [[buffer(2)]],uint id [[thread_position_in_grid]]) {
    if(id>=p.work.y)return;
    Path direct=paths[id*2],scattered=paths[id*2+1];
    colors[id]=float4(direct.radiance.rgb+scattered.radiance.rgb,(direct.ray.status.x==3 || scattered.ray.status.x==3)?-1.0f:1.0f);
}
