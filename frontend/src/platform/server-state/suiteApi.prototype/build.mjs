// Produce one double-clickable file from the isolated TypeScript sketch.
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const ts = require('typescript')
const here = path.dirname(fileURLToPath(import.meta.url))
const configPath = path.join(here, 'tsconfig.json')
const config = ts.readConfigFile(configPath, ts.sys.readFile)
const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, here)
const program = ts.createProgram(parsed.fileNames, parsed.options)
const diagnostics = ts.getPreEmitDiagnostics(program)
if (diagnostics.length) {
  process.stderr.write(
    ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCanonicalFileName: (file) => file,
      getCurrentDirectory: () => here,
      getNewLine: () => '\n',
    }),
  )
  process.exit(1)
}
const source = readFileSync(path.join(here, 'model.ts'), 'utf8')
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText
const vue = readFileSync(require.resolve('vue/dist/vue.global.prod.js'), 'utf8')
const template = readFileSync(path.join(here, 'template.html'), 'utf8')
const html = template
  .replace('/* VUE_RUNTIME */', () => vue)
  .replace('/* PROTOTYPE_MODEL */', () => compiled)
writeFileSync(path.join(here, 'demo.html'), html)
console.log('Caller types checked, including seven rejected call shapes. Built demo.html.')
