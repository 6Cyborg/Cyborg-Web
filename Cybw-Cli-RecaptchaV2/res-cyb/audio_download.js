async function fn(url) {
  const resp = await fetch(url, {credentials:'include'});
  const blob = await resp.blob();
  return await new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onload = () => resolve(fr.result.split(',')[1]);
    fr.onerror = () => reject("read error");
    fr.readAsDataURL(blob);
  });
}

