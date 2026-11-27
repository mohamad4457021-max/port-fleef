'use strict';
// Preserve the existing email confirmation and password recovery redirect.
function isAuthCallback(href){
 const u=new URL(href),p=new URLSearchParams(u.hash.slice(1));
 return ['access_token','refresh_token','error','error_code','error_description'].some(k=>p.has(k))||['code','error_code'].some(k=>u.searchParams.has(k));
}
if(isAuthCallback(location.href)){
 const u=new URL(location.href),target=new URL('./owner.html',u.href);
 for(const k of ['code','error','error_code','error_description','access_token','refresh_token','token_type','expires_in'])if(u.searchParams.has(k))target.searchParams.set(k,u.searchParams.get(k));
 target.hash=u.hash;
 location.replace(target.href);
}else if('serviceWorker' in navigator&&window.isSecureContext){
 navigator.serviceWorker.register('./sw.js',{scope:'./',updateViaCache:'none'}).catch(()=>{});
}
