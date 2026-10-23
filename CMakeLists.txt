cmake_minimum_required(VERSION 3.20)

project(myslowroll-cc VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

include(GNUInstallDirs)
include(CTest)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickControls2 Network Test)
find_package(KF6Kirigami 6.0 REQUIRED)

add_definitions(-DMYSLOWROLL_CC_VERSION="${PROJECT_VERSION}")

set_source_files_properties(qml/components/UiMetrics.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

add_library(myslowroll_core STATIC
    src/DesktopBackend.h
    src/DesktopBackend.cpp
    src/SlowrollBackend.h
    src/SlowrollBackend.cpp
)

target_link_libraries(myslowroll_core PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    KF6::Kirigami
)

qt_add_executable(myslowroll-cc
    src/main.cpp
)

qt_add_qml_module(myslowroll-cc
    URI org.myslowrollos.controlcenter
    VERSION 1.0
    RESOURCE_PREFIX "/qt/qml"
    QML_FILES
        qml/Main.qml
        qml/components/UiMetrics.qml
        qml/components/StatCard.qml
        qml/components/OutputCard.qml
        qml/modules/DashboardModule.qml
        qml/modules/SoftwareModule.qml
        qml/modules/ServicesNetworkModule.qml
        qml/modules/SystemModule.qml
        qml/modules/RecoveryModule.qml
        qml/modules/CommandsModule.qml
        qml/modules/ToolsModule.qml
)

target_link_libraries(myslowroll-cc PRIVATE
    myslowroll_core
)

set_target_properties(myslowroll-cc PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

install(TARGETS myslowroll-cc
    BUNDLE DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(FILES data/myslowroll-cc.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)

install(FILES data/icons/hicolor/scalable/apps/myslowroll-cc.svg
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
)

install(FILES data/org.myslowrollos.controlcenter.policy
    DESTINATION ${CMAKE_INSTALL_DATADIR}/polkit-1/actions
)

install(FILES data/org.myslowrollos.controlcenter.metainfo.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo
)

install(PROGRAMS data/scripts/mic.sh data/scripts/privacy.sh
    DESTINATION ${CMAKE_INSTALL_DATADIR}/myslowroll-cc/scripts
)

if(BUILD_TESTING)
    add_executable(test_domain
        tests/test_domain.cpp
    )

    target_link_libraries(test_domain PRIVATE
        myslowroll_core
        Qt6::Test
    )

    add_test(NAME DomainTest COMMAND test_domain)
    set_tests_properties(DomainTest PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()


