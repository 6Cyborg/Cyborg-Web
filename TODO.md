# 6Cyborg-Web TODO list

[ ] configuration profiles (proxy, pays, langue) à revoir
[ ] auto-wait : `cybw all` est intégré à _tap_ et _input_.

## Complex CSS selector

```
const card = page.locator('div.rounded-sm.border', {
  has: page.getByRole('heading', { name: 'Triple Monsters' })
});
await card.getByRole('button').click();
```
