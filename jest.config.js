/** Solo las pruebas del acomodo en TS (src/layout.ts); no cargan el módulo nativo. */
module.exports = {
  testEnvironment: 'node',
  testRegex: '/__tests__/.*test\\.ts$',
  transform: {
    '^.+\\.ts$': ['babel-jest', { configFile: require.resolve('expo-module-scripts/babel.config.cli.js') }],
  },
};
