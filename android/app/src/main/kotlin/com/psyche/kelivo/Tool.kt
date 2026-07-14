package com.psyche.kelivo

/**
 * Base interface for AI-accessible Android native tools.
 * Each tool provides metadata (name, description, parameters) and an execute method.
 */
interface Tool {
    val name: String
    val description: String
    val parameters: Map<String, Any>
    suspend fun execute(args: Map<String, Any>): String
}
