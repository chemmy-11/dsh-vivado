/**
 * dsh-vivado-team-link :: lib/client.js — 浏览器侧配置卡片（Web GUI 的「设置 → 插件 → 本行 → 配置」）。
 *
 * ## 为什么要这个文件
 *
 * 决定 1 原本要求「零 React、靠 DSH 原生表单」。实测该机制在 DSH 0.2.2-rc.1 不存在：
 * 设置→插件的配置页是 **keyed slot `plugins.row.config`**，`@deepseek-ai/dsh-client-ui-settings`
 * 自述「自身不渲染任何界面」，全 asar 没有通用 occupant。所以面板只能由插件自己占位。
 * 这里用**手写 bundle + React.createElement**（无 JSX、无构建步骤、无 tsdown），
 * 只依赖平台冻结模块表里的 `react`。
 *
 * ## bundle 契约（照抄内置 bundle 的外壳，见 @deepseek-ai/dsh-client-ui-settings-plugins/lib/client.js）
 *
 *   window.__ModuleLoader__.load({ id: <包名>, factory: (require) => module.exports })
 *
 * `require` 只能解析平台模块表里的请求（react / react-dom / @deepseek-ai/dsh-client-ui-*），
 * 基座之外的请求要写进 package.json 的 `dsh.client.external`。本文件只用 `react`。
 *
 * ## 两个入口（同一份 profile 配置，改哪个都一样）
 *
 * 1. **设置里的一级分区**（默认入口，和「通用设置」「模型」同级）：
 *    `settings.section` slot，`id: team-link`、`order: 20`、`label: 'PC 协作（team-link）'`。
 *    一级分区拿不到宿主递来的表单对象，所以自己用 `ctx.configForms` 按命名空间取（见 TeamLinkSection）。
 * 2. **插件页里的行配置页**（第二入口）：keyed slot `plugins.row.config`，键 `<包名>#<行 id>`，
 *    宿主会把 `form` 作为 prop 递进来（见 TeamLinkRowConfig）。
 *
 * ## 卡片拿到的 props
 *
 * 宿主页面按 slot 分发：`{ view, form }`，另有 `t`（仅当注册时声明了 `locale`）。
 *   - `view === 'summary'`：列表卡片上的一行摘要，返回字符串/节点即可。
 *   - `form`：`{ state: { status, value, base, user, revision, writable }, mutate(ops, revision), set, unset }`
 *   - `mutate` 的 ops 是 `{ op: 'set', path: ['a2a','port'], value }` 数组；写入是**原子**的，
 *     冲突时返回 false（我们据此提示"已重新读取"）。
 *
 * ## 两个硬约束
 *
 * 1. **不显示、不写 token 值**。卡片只展示 token 的**文件路径**与**凭据引用名**（这两个是
 *    配置项里的非密字段）。是否"已配置"也不在本卡片读 —— 那要 `remote.credentials` 这类
 *    非必需服务，实测未 inject 就取会抛错并崩掉整张卡片；该状态由宿主工具
 *    `team_link_setup {action:"status"}` 权威回报。值的写入入口同样是它。
 * 2. **只写 Config 里 `.volatile()` 过的字段**。宿主拒绝写非 volatile 路径，所以宿主侧
 *    lib/index.js 的 Config 必须对这些字段调 `.volatile()`；两边是一套约定。
 *
 * @module dsh-vivado-team-link/client
 */

window.__ModuleLoader__.load({
  id: 'dsh-vivado-team-link',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement

    /** 本包在 profile 里的行 id（与 cordis.patch.yml.tmpl 的 `id: team-link` 一致）。 */
    const ROW_ID = 'team-link'
    /** keyed slot 的键：`<包名>#<行 id>`。 */
    const SLOT_KEYS = ['dsh-vivado-team-link#' + ROW_ID]
    /** 设置里的一级分区 id（导航项就靠它，与「通用设置」「模型」同级）。 */
    const SECTION_ID = 'team-link'
    /** 本行配置在 settings 镜像里的命名空间候选（按可能性排序）。 */
    const NAMESPACE_CANDIDATES = [ROW_ID, 'dsh-vivado-team-link#' + ROW_ID, 'include:' + ROW_ID, 'dsh-vivado-team-link']
    /**
     * 需要的服务：
     * - `slots`：注册设置分区 / 行内配置页；
     * - `configForms`：自己取本行的配置表单（一级分区拿不到宿主递来的 `form` prop，必须自己按
     *   entry id 取，见 §"设置分区的取表方式"）。
     */
    const inject = ['slots', 'configForms']

    // -----------------------------------------------------------------------
    //  极小工具
    // -----------------------------------------------------------------------

    /**
     * 按路径取值。
     * @param {unknown} source - 根对象。
     * @param {string[]} path - 键路径。
     * @returns {unknown} 值或 undefined。
     */
    function getIn(source, path) {
      let node = source
      for (const key of path) {
        if (node === null || typeof node !== 'object') return undefined
        node = node[key]
      }
      return node
    }

    /**
     * 按路径写值（返回新对象，不改原对象）。
     * @param {Record<string, unknown>} source - 根对象。
     * @param {string[]} path - 键路径。
     * @param {unknown} value - 新值。
     * @returns {Record<string, unknown>} 新对象。
     */
    function setIn(source, path, value) {
      const root = { ...(source || {}) }
      let node = root
      for (let i = 0; i < path.length - 1; i++) {
        const key = path[i]
        const next = node[key]
        node[key] = next !== null && typeof next === 'object' ? { ...next } : {}
        node = node[key]
      }
      node[path[path.length - 1]] = value
      return root
    }

    /**
     * 把值渲染成输入框里的字符串。
     * @param {unknown} value - 原值。
     * @returns {string} 文本。
     */
    function asText(value) {
      if (value === undefined || value === null) return ''
      return String(value)
    }

    /** 卡片里所有可编辑的标量字段（顺序即渲染顺序）。 */
    const FIELDS = [
      { path: ['role'], label: '角色', kind: 'select', options: [['pc1', 'pc1 —— 本机为 lead'], ['pc2', 'pc2 —— 板 B 侧组员']], hint: '决定日志/自检里的 machine 名，也决定默认 token 的用途。' },
      { path: ['machine'], label: '显示名', kind: 'text', hint: '留空则按角色自动取 PC1 / PC2。' },
      { path: ['a2a', 'host'], label: 'A2A 监听地址', kind: 'text', hint: '默认 127.0.0.1（只本机）。跨机请填实际网卡地址：WLAN / 第二网卡 / Tailscale，绝不用 192.168.1.x。' },
      { path: ['a2a', 'port'], label: 'A2A 端口', kind: 'number', min: 1, max: 65535 },
      { path: ['mcp', 'host'], label: 'MCP 监听地址', kind: 'text', hint: '同上：跨机才需要改。' },
      { path: ['mcp', 'port'], label: 'MCP 端口', kind: 'number', min: 1, max: 65535 },
      { path: ['peer', 'name'], label: '对端名字', kind: 'text' },
      { path: ['peer', 'a2aUrl'], label: '对端 A2A 地址', kind: 'text', hint: '例：http://10.0.0.9:7310/ ；空表示对端还没上线。' },
      { path: ['peer', 'mcpUrl'], label: '对端 MCP 地址', kind: 'text', hint: '例：http://10.0.0.9:18790/mcp ；拉证据要用它。' },
      { path: ['fallback', 'repo'], label: '回退仓库', kind: 'text', hint: 'owner/repo；通道断了就转这个仓库的 issue 轮询。' },
      { path: ['fallback', 'issueLabel'], label: '回退 issue 标签', kind: 'text' },
      { path: ['fallback', 'pollSeconds'], label: '轮询间隔（秒）', kind: 'number', min: 30 },
      { path: ['logDir'], label: '日志目录', kind: 'text', hint: '相对插件目录，或绝对路径。' },
    ]

    /** 四个 token 槽位：(配置里的路径前缀, 显示名)。值永不显示。 */
    const TOKEN_SLOTS = [
      { path: ['a2a'], label: '本机 A2A（入站）' },
      { path: ['mcp'], label: '本机 MCP（入站）' },
      { path: ['peer', 'a2a'], label: '对端 A2A（出站）' },
      { path: ['peer', 'mcp'], label: '对端 MCP（出站）' },
    ]

    // -----------------------------------------------------------------------
    //  样式（内联，避免再引入 CSS 模块/构建链；用宿主主题变量保证深浅色都对）
    // -----------------------------------------------------------------------

    const S = {
      root: { display: 'flex', flexDirection: 'column', gap: '14px', maxWidth: '760px', color: 'var(--dsw-alias-label-primary)' },
      grid: { display: 'grid', gridTemplateColumns: 'minmax(120px, 200px) minmax(0, 1fr)', gap: '10px 14px', alignItems: 'start' },
      label: { fontSize: '13px', color: 'var(--dsw-alias-label-secondary, var(--dsw-alias-label-primary))', paddingTop: '6px' },
      input: {
        width: '100%', boxSizing: 'border-box', fontSize: '13px', lineHeight: '20px', padding: '5px 8px',
        borderRadius: '6px', border: '1px solid var(--dsw-alias-border-l2)', background: 'var(--dsw-alias-bg-l1, transparent)',
        color: 'inherit', fontFamily: 'inherit',
      },
      hint: { fontSize: '12px', lineHeight: '18px', color: 'var(--dsw-alias-label-tertiary)', margin: '4px 0 0 0' },
      err: { fontSize: '12px', lineHeight: '18px', color: 'var(--dsw-alias-state-danger, #c0392b)', margin: '4px 0 0 0' },
      sectionTitle: { fontSize: '13px', fontWeight: 600, margin: '2px 0 0 0' },
      intro: { fontSize: '13px', lineHeight: '20px', color: 'var(--dsw-alias-label-tertiary)', margin: 0 },
      box: {
        border: '1px solid var(--dsw-alias-border-l2)', borderRadius: '8px', padding: '10px 12px',
        display: 'flex', flexDirection: 'column', gap: '6px', fontSize: '12px', lineHeight: '18px',
      },
      row: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' },
      code: { fontFamily: 'ui-monospace, Consolas, monospace', fontSize: '12px', wordBreak: 'break-all' },
      badgeOk: { fontSize: '11px', padding: '1px 7px', borderRadius: '999px', border: '1px solid var(--dsw-alias-border-l2)', color: 'var(--dsw-alias-state-success, #1e8449)' },
      badgeNo: { fontSize: '11px', padding: '1px 7px', borderRadius: '999px', border: '1px solid var(--dsw-alias-border-l2)', color: 'var(--dsw-alias-label-tertiary)' },
      btn: { fontSize: '13px', lineHeight: '20px', padding: '5px 14px', borderRadius: '6px', border: '1px solid var(--dsw-alias-border-l2)', background: 'transparent', color: 'inherit', cursor: 'pointer', fontFamily: 'inherit' },
      btnPrimary: { fontSize: '13px', lineHeight: '20px', padding: '5px 14px', borderRadius: '6px', border: '1px solid transparent', background: 'var(--dsw-alias-state-business-primary, #4D6BFE)', color: '#fff', cursor: 'pointer', fontFamily: 'inherit' },
      note: { fontSize: '12px', lineHeight: '18px', color: 'var(--dsw-alias-label-tertiary)', margin: 0 },
    }

    // -----------------------------------------------------------------------
    //  roots：一行一条 `id=path[:ro|rw]`
    // -----------------------------------------------------------------------

    /**
     * 把 config 的 roots 数组渲染成文本。
     * @param {unknown} roots - [{ id, path, mode }]。
     * @returns {string} 文本。
     */
    function rootsToText(roots) {
      if (!Array.isArray(roots)) return ''
      return roots
        .filter((root) => root !== null && typeof root === 'object')
        .map((root) => asText(root.id) + '=' + asText(root.path) + (root.mode === 'ro' ? ':ro' : ''))
        .join('\n')
    }

    /**
     * 解析 roots 文本。
     * @param {string} text - 文本。
     * @returns {{ roots: Array<{ id: string, path: string, mode: string }>, error: string }} 结果或错误。
     */
    function parseRoots(text) {
      const roots = []
      const lines = String(text || '').split(/\r?\n/)
      for (let i = 0; i < lines.length; i++) {
        const raw = lines[i].trim()
        if (raw === '' || raw.startsWith('#')) continue
        const eq = raw.indexOf('=')
        if (eq <= 0) return { roots: [], error: '第 ' + (i + 1) + ' 行缺少 "="，格式应为 id=path 或 id=path:ro' }
        const id = raw.slice(0, eq).trim()
        let rest = raw.slice(eq + 1).trim()
        let mode = 'rw'
        if (rest.endsWith(':ro')) { mode = 'ro'; rest = rest.slice(0, -3).trim() }
        else if (rest.endsWith(':rw')) { mode = 'rw'; rest = rest.slice(0, -3).trim() }
        if (id === '') return { roots: [], error: '第 ' + (i + 1) + ' 行 id 为空' }
        if (rest === '') return { roots: [], error: '第 ' + (i + 1) + ' 行 path 为空' }
        roots.push({ id, path: rest.replace(/\\/g, '/'), mode })
      }
      return { roots, error: '' }
    }

    // -----------------------------------------------------------------------
    //  表单主体（两种入口共用：设置里的一级分区 / 插件页里的行配置页）
    // -----------------------------------------------------------------------

    /**
     * 渲染配置表单本体。
     *
     * 两种入口的差别只在"怎么拿到 `form`"：
     * - 一级设置分区：拿不到宿主递来的 props，自己用 `configForms` 按 entry id 取（见 TeamLinkSection）；
     * - 插件页的行配置页：宿主直接把 `form` 递进来（见 TeamLinkRowConfig）。
     *
     * @param {{ view?: string, form?: any, page?: boolean }} props - `form` 是 `{ state, mutate }`。
     * @returns {unknown} React 节点或字符串。
     */
    function TeamLinkForm(props) {
      const view = props.view
      const form = props.form
      const page = props.page === true

      if (view === 'summary') return 'PC1↔PC2 协作层：通道 / 对端 / 授权根 / token 引用（值不在配置里）'

      const state = form && form.state ? form.state : undefined
      const value = state && state.value ? state.value : undefined
      const ready = state !== undefined && state.status === 'ready' && value !== undefined

      // 草稿：字符串化的字段值 + roots 文本。value 变化且没有未保存改动时重新同步。
      const [draft, setDraft] = React.useState({})
      const [rootsText, setRootsText] = React.useState('')
      const [dirty, setDirty] = React.useState(false)
      const [pending, setPending] = React.useState(false)
      const [notice, setNotice] = React.useState('')
      const [failure, setFailure] = React.useState('')

      const revision = state !== undefined ? state.revision : undefined
      React.useEffect(() => {
        if (!ready || dirty) return
        const next = {}
        for (const field of FIELDS) next[field.path.join('.')] = asText(getIn(value, field.path))
        setDraft(next)
        setRootsText(rootsToText(value.roots))
      }, [ready, revision, dirty, value])

      // 注意：卡片不请求凭据存储（见 apply 里那段说明），所以这里没有"是否已配置"的徽章。

      if (state === undefined) {
        return h('p', { style: S.hint }, '这个 profile 当前没有为本插件提供配置表单（宿主没把本行当作可配置条目）。配置仍可在 profile 的 cordis 补丁里改。')
      }
      if (state.status !== 'ready') {
        return h('p', { style: S.hint }, '正在读取配置…（状态：' + asText(state.status) + '）')
      }
      if (value === undefined) {
        return h('p', { style: S.hint }, '配置尚未就绪。')
      }

      const writable = state.writable !== false

      /**
       * 改一个草稿字段。
       * @param {string[]} path - 字段路径。
       * @param {string} text - 输入框文本。
       */
      const edit = (path, text) => {
        const key = path.join('.')
        setDraft((previous) => ({ ...previous, [key]: text }))
        setDirty(true)
        setNotice('')
        setFailure('')
      }

      /** 一次性把草稿里的改动提交成原子 mutate。 */
      const save = async () => {
        setFailure('')
        setNotice('')
        const ops = []
        const problems = []
        for (const field of FIELDS) {
          const key = field.path.join('.')
          const current = getIn(value, field.path)
          const text = (draft[key] !== undefined ? draft[key] : asText(current)).trim()
          if (field.kind === 'number') {
            const numeric = Number(text)
            if (text === '' || !Number.isFinite(numeric)) { problems.push(field.label + ' 必须是数字'); continue }
            if (field.min !== undefined && numeric < field.min) { problems.push(field.label + ' 不能小于 ' + field.min); continue }
            if (field.max !== undefined && numeric > field.max) { problems.push(field.label + ' 不能大于 ' + field.max); continue }
            if (numeric !== current) ops.push({ op: 'set', path: field.path, value: numeric })
          } else if (field.kind === 'select') {
            const allowed = field.options.map((pair) => pair[0])
            if (allowed.indexOf(text) < 0) { problems.push(field.label + ' 只能是 ' + allowed.join(' / ')); continue }
            if (text !== current) ops.push({ op: 'set', path: field.path, value: text })
          } else if (text !== asText(current)) {
            ops.push({ op: 'set', path: field.path, value: text })
          }
        }

        const parsed = parseRoots(rootsText)
        if (parsed.error !== '') problems.push('授权根：' + parsed.error)
        else if (JSON.stringify(parsed.roots) !== JSON.stringify(value.roots || [])) {
          ops.push({ op: 'set', path: ['roots'], value: parsed.roots })
        }

        if (problems.length > 0) { setFailure(problems.join('；')); return }
        if (ops.length === 0) { setNotice('没有改动。'); setDirty(false); return }

        setPending(true)
        try {
          const accepted = await form.mutate(ops, revision)
          if (accepted) {
            setDirty(false)
            setNotice('已保存 ' + ops.length + ' 项。宿主已物化 state/config.json；A2A/MCP 是启动时读配置，**重启宿主后生效**。')
          } else {
            setNotice('保存被拒绝（多半是并发修改）。已重新读取，请重试。')
            setDirty(false)
          }
        } catch (error) {
          setFailure('保存失败：' + asText(error && error.message ? error.message : error))
        } finally {
          setPending(false)
        }
      }

      /** 丢弃草稿，回到宿主当前值。 */
      const reset = () => {
        const next = {}
        for (const field of FIELDS) next[field.path.join('.')] = asText(getIn(value, field.path))
        setDraft(next)
        setRootsText(rootsToText(value.roots))
        setDirty(false)
        setFailure('')
        setNotice('已丢弃未保存的改动。')
      }

      const children = []

      // 一级设置分区当页面用时，标题跟「通用设置 / 模型」一样由页面自己给（分区本身只占导航项）。
      if (page) {
        children.push(h('h2', {
          key: 'page-title',
          style: { margin: 0, fontSize: '18px', fontWeight: 600, lineHeight: '26px' },
        }, 'PC 协作（team-link）'))
        children.push(h('p', { key: 'page-intro', style: S.intro }, 'PC1↔PC2 两机协作层：A2A(7310) / MCP(18790) 双通道，断了退回 GitHub issue 轮询。'))
      }
      // 一级分区页面已经有自己的大标题，就不再重复一遍小节标题。
      if (!page) children.push(h('p', { key: 'title', style: S.sectionTitle }, 'PC1↔PC2 协作层（team-link）'))
      children.push(h('p', { key: 'intro', style: S.hint },
        '这里的改动写进 profile 配置，并由宿主插件物化成 state/config.json。',
        'token 的**值**不在这里：配置只保存文件路径与凭据引用名，值请用宿主工具 team_link_setup 写入 DSH 凭据存储。'))

      const grid = []
      for (const field of FIELDS) {
        const key = field.path.join('.')
        const text = draft[key] !== undefined ? draft[key] : asText(getIn(value, field.path))
        grid.push(h('label', { key: key + '-label', style: S.label, htmlFor: 'tl-' + key }, field.label))
        if (field.kind === 'select') {
          grid.push(h('div', { key: key + '-ctl' },
            h('select', {
              id: 'tl-' + key,
              style: S.input,
              value: text,
              disabled: !writable || pending,
              onChange: (event) => edit(field.path, event.currentTarget.value),
            }, field.options.map((pair) => h('option', { key: pair[0], value: pair[0] }, pair[1]))),
            field.hint ? h('p', { style: S.hint }, field.hint) : null))
        } else {
          grid.push(h('div', { key: key + '-ctl' },
            h('input', {
              id: 'tl-' + key,
              type: field.kind === 'number' ? 'number' : 'text',
              style: S.input,
              value: text,
              disabled: !writable || pending,
              min: field.min,
              max: field.max,
              spellCheck: false,
              onChange: (event) => edit(field.path, event.currentTarget.value),
            }),
            field.hint ? h('p', { style: S.hint }, field.hint) : null))
        }
      }
      children.push(h('div', { key: 'grid', style: S.grid }, grid))

      // 授权根
      children.push(h('div', { key: 'roots' },
        h('p', { style: S.sectionTitle }, '授权根目录（roots）'),
        h('p', { style: S.hint }, '一行一条：id=绝对路径，需要只读就写 id=路径:ro。服务端只允许访问这里列出的目录；路径必须存在且不要用 192.168.1.x 相关挂载。'),
        h('textarea', {
          style: { ...S.input, minHeight: '76px', fontFamily: 'ui-monospace, Consolas, monospace', resize: 'vertical' },
          value: rootsText,
          disabled: !writable || pending,
          spellCheck: false,
          placeholder: '留空 = 沿用 state/config.json 里既有的 roots（不会被覆盖）',
          onChange: (event) => { setRootsText(event.currentTarget.value); setDirty(true); setNotice(''); setFailure('') },
        }),
        h('p', { style: S.hint },
          (rootsText.trim() === ''
            ? '当前框里是空的：这表示本配置项**没有声明 roots**，物化时会沿用 state/config.json 里已有的授权根（state / evidence / delivery 等），不会被清空。'
            : '框里非空：保存后这一整张表会**替换** config.json 的 roots，请把要用的根全部列出。'))))

      // token 槽位的**引用名与文件路径**（这两个是配置项里的非密字段，宿主会 serve）。
      // 这里刻意**不读凭据存储**：那需要 `remote.credentials` 这类非必需服务，
      // 而实测「未 inject 就取」会抛错、把整张卡片从 slot 里崩掉；为了一个徽章去赌
      // 整个面板挂不挂载不划算。真实状态由宿主工具 team_link_setup {action:"status"} 权威回报。
      const tokenRows = []
      for (const slot of TOKEN_SLOTS) {
        const ref = asText(getIn(value, slot.path.concat('tokenRef')))
        const file = asText(getIn(value, slot.path.concat('tokenFile')))
        tokenRows.push(h('div', { key: 'tk-' + slot.path.join('.'), style: S.row },
          h('span', { style: { minWidth: '150px' } }, slot.label),
          h('span', { style: S.code }, ref === '' ? '（未设引用名）' : ref),
          h('span', { style: { ...S.code, opacity: 0.6 } }, file === '' ? '' : '→ ' + file)))
      }
      tokenRows.push(h('p', { key: 'tk-note', style: S.hint },
        'token 值只存在于 DSH 凭据存储（~/.dsh/.credentials.yaml 的 refs 段），本卡片与任何工具都不会显示它。',
        '写入/清除请用宿主工具：team_link_setup {action:"set-token", token:"a2a", value:"…"}。'))
      children.push(h('div', { key: 'tokens', style: S.box },
        h('p', { style: S.sectionTitle }, 'token（只看存在性，不看值）'),
        tokenRows))

      // 操作条
      children.push(h('div', { key: 'actions', style: S.row },
        h('button', { style: writable ? S.btnPrimary : S.btn, disabled: !writable || pending || !dirty, onClick: save },
          pending ? '保存中…' : '保存'),
        h('button', { style: S.btn, disabled: pending || !dirty, onClick: reset }, '丢弃改动'),
        h('span', { style: { fontSize: '12px', color: 'var(--dsw-alias-label-tertiary)' } },
          dirty ? '有未保存的改动' : '已与宿主同步')))

      if (failure !== '') children.push(h('p', { key: 'fail', style: S.err }, failure))
      if (notice !== '') children.push(h('p', { key: 'notice', style: S.note }, notice))
      if (!writable) children.push(h('p', { key: 'ro', style: S.err }, '这个 profile 把本行配置标成了不可写（只读层），卡片只能看不能改。'))
      children.push(h('p', { key: 'tail', style: S.note },
        '提示：config.json 由宿主插件在启动时物化；A2A(7310) / MCP(18790) 两个服务只在启动时读 token 与端口，改完请重启宿主。'))

      return h('section', { style: S.root, 'data-dsh-plugin': 'dsh-vivado-team-link' }, children)
    }

    // -----------------------------------------------------------------------
    //  入口 1：设置里的一级分区（和「通用设置」「模型」同级）
    // -----------------------------------------------------------------------

    /**
     * 把 `configForms` 的 ConfigForm（`getSnapshot/subscribe/mutate`）适配成表单主体要的 `{ state, mutate }`。
     *
     * 为什么一级分区要自己取表：宿主只对 `plugins.row.config` 这类 **keyed slot** 递 `form` prop；
     * 一级分区（`settings.section`）拿到的 props 只有 `t` 之类，没有任何表单对象。
     * 官方页面（模型/网页搜索）都是走 `ctx.configForms` 自己取。
     *
     * @param {any} configForms - 客户端配置表单服务（`ctx.configForms`）。
     * @param {string} entryId - 本行在 settings 镜像里的命名空间 id。
     * @returns {{ state: any, mutate: (ops: any[], revision: any) => Promise<boolean> } | undefined} 适配后的表单。
     */
    function useConfigForm(configForms, entryId) {
      const [snapshot, setSnapshot] = React.useState(undefined)
      const [api, setApi] = React.useState(undefined)

      React.useEffect(() => {
        setApi(undefined)
        setSnapshot(undefined)
        if (!configForms || typeof configForms.get !== 'function' || entryId === undefined) return undefined
        let form
        try {
          form = configForms.get(entryId)
        } catch {
          // 该 id 不被本部署服务：保持未就绪，页面会渲染"暂不可用"。
          return undefined
        }
        if (form === undefined || form === null) return undefined
        setApi(form)
        const sync = () => {
          try { setSnapshot(form.getSnapshot()) } catch { /* 读失败当作未就绪 */ }
        }
        sync()
        let off
        try { off = form.subscribe(sync) } catch { off = undefined }
        return () => { if (typeof off === 'function') off() }
      }, [configForms, entryId])

      if (api === undefined) return undefined
      return {
        state: snapshot,
        mutate: (ops, revision) => api.mutate(ops, revision),
      }
    }

    /**
     * 一级设置分区页面：自己从 settings 镜像里解析出本行的命名空间，再取表单。
     * @param {{ configForms?: any }} props - 由 apply 闭包注入 `configForms`。
     * @returns {unknown} React 节点。
     */
    function TeamLinkSection(props) {
      const configForms = props.configForms

      // 订阅 settings 镜像，找出本行被服务的命名空间。
      const [namespaces, setNamespaces] = React.useState([])
      React.useEffect(() => {
        if (!configForms || typeof configForms.describe !== 'function') return undefined
        let mirror
        try { mirror = configForms.describe() } catch { return undefined }
        if (mirror === undefined || mirror === null) return undefined
        const read = () => {
          try {
            const view = mirror.getSnapshot() ? mirror.getSnapshot().view : undefined
            const rows = view && Array.isArray(view.namespaces) ? view.namespaces : []
            setNamespaces(rows.map((row) => asText(row && row.ns)).filter((ns) => ns !== ''))
          } catch {
            setNamespaces([])
          }
        }
        read()
        let off
        try { off = mirror.subscribe(read) } catch { off = undefined }
        return () => { if (typeof off === 'function') off() }
      }, [configForms])

      const entryId = React.useMemo(() => {
        for (const candidate of NAMESPACE_CANDIDATES) {
          if (namespaces.indexOf(candidate) >= 0) return candidate
        }
        return undefined
      }, [namespaces.join(',')])

      const form = useConfigForm(configForms, entryId)

      if (configForms === undefined) {
        return h('section', { style: S.root },
          h('h2', { style: { margin: 0, fontSize: '18px', fontWeight: 600 } }, 'PC 协作（team-link）'),
          h('p', { style: S.err }, '这个部署没有提供配置表单服务（configForms），本页无法编辑配置。配置仍可在 profile 的 cordis 补丁里改。'))
      }
      if (entryId === undefined) {
        return h('section', { style: S.root },
          h('h2', { style: { margin: 0, fontSize: '18px', fontWeight: 600 } }, 'PC 协作（team-link）'),
          h('p', { style: S.hint }, '宿主还没有把本插件的配置行挂起来（行 id `team-link`）。',
            '通常意味着 bundle 已注册但宿主未重启，或这一行被禁用。重启宿主后本页会自动出现表单。'))
      }
      return h(TeamLinkForm, { form, view: 'page', page: true })
    }

    // -----------------------------------------------------------------------
    //  入口 2：插件页里的行配置页（第二入口，保留）
    // -----------------------------------------------------------------------

    /**
     * 插件页 `plugins.row.config` 的占位组件：宿主会把 `form` 直接递进来。
     * @param {{ view?: string, form?: any }} props - 宿主 slot props。
     * @returns {unknown} React 节点或字符串。
     */
    function TeamLinkRowConfig(props) {
      return h(TeamLinkForm, { form: props.form, view: props.view, page: false })
    }

    /**
     * 注册两个入口：设置里的一级分区 + 插件页里的行配置页。
     * @param {any} ctx - 浏览器侧 Cordis 上下文。
     */
    function apply(ctx) {
      const slots = ctx && ctx.slots
      if (!slots || typeof slots.inject !== 'function') return

      // `configForms` 声明在模块出口的 inject 里；这里只做防御性读取（拿不到就渲染"不可用"而不是崩）。
      let configForms
      try { configForms = ctx.configForms } catch { configForms = undefined }

      // —— 入口 1：设置里的一级分区。order 20 = 排在「通用设置」(0)、「模型」(10)、「插件」(15) 之后，
      //    与它们是同一级导航项，不是塞在插件页里。label 用静态中文（分区 label 接受字符串）。——
      slots.inject('settings.section', () => slots.register({
        name: 'settings.section',
        id: SECTION_ID,
        order: 20,
        label: 'PC 协作',
      }, () => h(TeamLinkSection, { configForms })))

      // —— 入口 2：插件页里的行配置页（保留：两个入口改的是同一份 profile 配置）。——
      slots.inject('plugins.row.config', () => {
        const disposers = []
        for (const key of SLOT_KEYS) {
          try {
            disposers.push(slots.register({ name: 'plugins.row.config', key }, TeamLinkRowConfig))
          } catch (error) {
            // 该行不可配置时宿主会拒绝注册：不影响其他键，但要留痕（面板不出现时靠这行排查）。
            // eslint-disable-next-line no-console
            try { console.warn('[team-link] 注册行配置页失败 key=' + key + ' -> ' + (error && error.message ? error.message : error)) } catch {}
          }
        }
        return () => { for (const dispose of disposers) dispose() }
      })
    }

    const module = { exports: {} }
    module.exports.apply = apply
    module.exports.inject = inject
    return module.exports
  },
})
