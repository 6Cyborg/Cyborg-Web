# 6Cyborg-Web TODO list

[ ] configuration profiles (proxy, pays, langue) à revoir

## Complex CSS selector

```
const card = page.locator('div.rounded-sm.border', {
  has: page.getByRole('heading', { name: 'Triple Monsters' })
});
await card.getByRole('button').click();
```
