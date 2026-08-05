# Architecture

Applications
    -> Wrapper (Update.ps1 / Language.ps1)
        -> Tool (UpdateProject / LanguageProject)
            -> Core framework

Tools are siblings and must never depend on each other.
