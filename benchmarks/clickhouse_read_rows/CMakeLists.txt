if (NOT TARGET dbms)
    message(FATAL_ERROR "clickhouse-read-rows must be added after ClickHouse declares the dbms target")
endif()

option(CLICKHOUSE_READ_ROWS_PROFILE "Instrument ClickHouse readRows operation scopes" OFF)

if (NOT TARGET clickhouse-read-rows)
    add_executable(clickhouse-read-rows "${CMAKE_CURRENT_LIST_DIR}/read_rows.cpp")
    target_link_libraries(clickhouse-read-rows PRIVATE dbms)
endif()

if (CLICKHOUSE_READ_ROWS_PROFILE)
    target_compile_definitions(clickhouse-read-rows PRIVATE CLICKHOUSE_READ_ROWS_PROFILE=1)
    target_include_directories(clickhouse-read-rows PRIVATE "${CMAKE_CURRENT_LIST_DIR}")

    set(clickhouse_read_rows_profile_sources
        "${CMAKE_SOURCE_DIR}/src/IO/ReadBufferFromFileDescriptor.cpp"
        "${CMAKE_SOURCE_DIR}/src/IO/OpenedFile.cpp"
        "${CMAKE_SOURCE_DIR}/src/Compression/CompressedReadBufferBase.cpp"
        "${CMAKE_SOURCE_DIR}/src/Compression/CompressedReadBufferFromFile.cpp"
        "${CMAKE_SOURCE_DIR}/src/Compression/CompressionCodecLZ4.cpp")

    foreach(profile_source IN LISTS clickhouse_read_rows_profile_sources)
        set_property(SOURCE "${profile_source}" TARGET_DIRECTORY dbms APPEND
            PROPERTY COMPILE_DEFINITIONS CLICKHOUSE_READ_ROWS_PROFILE=1)
        set_property(SOURCE "${profile_source}" TARGET_DIRECTORY dbms APPEND
            PROPERTY INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}")
    endforeach()
endif()
