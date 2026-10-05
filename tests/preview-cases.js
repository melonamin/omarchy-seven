// The same hostile corpus exercises both the source invariant and real Qt.
module.exports = function previewCases(base) {
  const cases = []
  const add = build => {
    const url = `${base}/case-${cases.length}`
    cases.push(build(url))
  }
  for (let markers = 1; markers <= 16; markers++) {
    for (let slashes = 0; slashes <= 5; slashes++) {
      const prefix = '\\'.repeat(slashes) + '!'.repeat(markers)
      add(url => `${prefix}[inline](${url})`)
      add(url => `${prefix}[full][ref]\n\n[ref]: ${url}`)
      add(url => `${prefix}[collapsed][]\n\n[collapsed]: ${url}`)
      add(url => `${prefix}[shortcut]\n\n[shortcut]: ${url}`)
    }
  }
  for (const prefix of ['&#33;', '&#x21;', '&excl;', '!&#91;', '!\\[', '!\n[', '!\0[', '!\u200b[']) {
    add(url => `${prefix}[entity](${url})`)
  }
  for (const tag of [
    url => `<img src="${url}"/>`,
    url => `<IMG SRC='${url}'></IMG>`,
    url => `Inline <img src=${url}/> image`,
    url => `<div><img src="${url}"></div>`,
    url => `<table background="${url}"><tr><td>x</td></tr></table>`,
    url => `<span style="background-image:url(${url})">x</span>`,
    url => `<style>body { background-image: url(${url}); }</style>`,
    url => `&lt;img src="${url}"/&gt;`,
    url => `&#60;img src="${url}"/&#62;`,
    url => `&#x3c;img src="${url}"/&#x3e;`,
    url => `&amp;lt;img src="${url}"/&amp;gt;`,
    url => `<!-- comment --><img src="${url}"/>`,
    url => `<![CDATA[<img src="${url}"/>]]>`,
    url => `[outer !![inner](${url})](https://example.test)`,
    url => `!![outer ![inner](${url})](${url})`,
    url => `> !![quote](${url})\n\n- !!![list](${url})`,
    url => `\`!![code](${url})\`\n\n~~~\n<img src="${url}"/>\n~~~`,
    url => `[ordinary link](${url})\n\n<${url}>`
  ]) add(tag)
  return cases
}
