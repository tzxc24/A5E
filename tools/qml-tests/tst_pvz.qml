import QtQuick 2.15
import QtTest 1.2
import QtQuick.Controls 2.15
import "../../qml/apps"

Item {
    id: window
    width: 1280; height: 750
    property string uiFont: "Microsoft YaHei"
    QtObject {
        id: systemBackend
        property string saved: ""
        function saveAppData(key, value) { saved = value }
        function loadAppData(key, fallback) { return saved || fallback }
    }
    Component { id: gameComponent; PvZApp {} }
    StackView { id: lifecycleStack; width: 1280; height: 750; initialItem: Item {} }
    TestCase {
        name: "PvZGameplay"
        when: windowShown
        property var game
        function init() {
            systemBackend.saved = ""
            game = gameComponent.createObject(window, {width: 1280, height: 750})
            verify(game !== null)
            game.gamePaused = true
        }
        function cleanup() { if (game) game.destroy(); wait(0) }
        function test_popSavesAndDestroys() {
            lifecycleStack.push(game, StackView.Immediate)
            game.sun = 17
            lifecycleStack.pop(StackView.Immediate)
            wait(20)
            compare(game, null)
            compare(JSON.parse(systemBackend.saved).sun, 17)
            var reopened = gameComponent.createObject(window, {width:1280,height:750})
            verify(reopened.gameRunning); verify(!reopened.leaving)
            compare(reopened.sun, 17)
            reopened.destroy(); wait(0)
        }
        function test_sunTapSurvivesTicks() {
            game.gamePaused = false
            game.sunsList = [{id:42,x:200,y:100,targetY:100,val:25,isFalling:false,opacity:1,lifetime:14}]
            wait(20)
            var target = findChild(game, "pvz-sun-42")
            verify(target !== null)
            mousePress(target, 26, 26)
            wait(180)
            mouseRelease(target, 26, 26)
            compare(game.sun, 175)
        }
        function test_pauseStopsSimulation() {
            game.startNewGame(1)
            game.gamePaused = true
            game.cardCooldowns = [1,0,0,0,0,0,0,0]
            wait(100)
            compare(game.cardCooldowns[0], 1)
        }
        function test_plantingAndOccupiedTile() {
            game.gamePaused = false
            game.selectCard(0); game.handleTileClick(2,3)
            compare(game.sun, 100); compare(game.gridPlants.length, 1)
            game.selectCard(1); game.handleTileClick(2,3)
            compare(game.sun, 100); compare(game.gridPlants.length, 1)
        }
        function test_savePreservesZeroAndExit() {
            game.sun = 0; game.saveGame()
            verify(game.loadSavedGame()); compare(game.sun, 0)
            game.exitGame()
            verify(JSON.parse(systemBackend.saved).hasSave)
        }
        function test_finalWaveStopsSpawning() {
            game.wave = game.maxWaves; game.waveProgress = 1
            game.zombiesList = []; game.spawnNextZombie()
            compare(game.zombiesList.length, 0)
            game.gamePaused = false; game.updateGameEngine()
            verify(game.gameWon)
        }
        function test_mowerCannotRestart() {
            game.startLawnMower(0)
            verify(!game.lawnMowers[0])
            game.mowerPositions = [-99,-1,-1,-1,-1]
            game.startLawnMower(0)
            compare(game.mowerPositions[0], -99)
        }
        function test_projectileKillsOneZombie() {
            game.spawnZombieRow(2,"regular")
            var z = game.zombiesList[0]; z.x = 300; z.hp = 20
            game.zombiesList = [z]
            game.projectilesList = [{row:2,x:320,y:220,speed:1,damage:20,type:"pea"}]
            game.gamePaused = false; game.updateGameEngine()
            compare(game.zombiesList.length, 0); compare(game.score, 20)
        }
        function test_mowerClearsAdjacentZombies() {
            game.spawnZombieRow(1,"regular"); game.spawnZombieRow(1,"regular")
            var list = game.zombiesList
            list[0].x = 5; list[1].x = 6; game.zombiesList = list
            game.gamePaused = false; game.updateGameEngine()
            compare(game.zombiesList.length, 0)
            compare(game.score, 40)
            verify(!game.lawnMowers[1])
        }
        function test_invalidSaveStartsFresh() {
            systemBackend.saved = "{broken"
            verify(!game.loadSavedGame())
            game.startNewGame(1)
            compare(game.sun, 150); compare(game.gridPlants.length, 0)
        }
        function test_invalidTileDoesNotSpendSun() {
            game.gamePaused = false; game.selectCard(0)
            game.handleTileClick(-1,0); game.handleTileClick(0,9)
            compare(game.sun, 150); compare(game.gridPlants.length, 0)
        }
        function test_shovelRemovesPlant() {
            game.gamePaused = false; game.selectCard(0); game.handleTileClick(0,0)
            game.selectShovel(); game.handleTileClick(0,0)
            compare(game.gridPlants.length, 0); verify(!game.shovelMode)
        }
    }
}
